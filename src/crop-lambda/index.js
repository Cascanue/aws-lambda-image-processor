// crop-lambda
// Diagrama: S3 (uploads/) -> notificación ObjectCreated -> SQS -> [esta Lambda] -> S3 (processed/)
//
// La Lambda recibe lotes de hasta 5 mensajes de SQS (Event Source Mapping).
// Cada mensaje contiene una notificación de S3; por cada imagen subida genera
// un PNG circular de 40x40 con fondo transparente.

const path = require("path");
const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const sharp = require("sharp");

// Se crea fuera del handler para reutilizarlo entre invocaciones (contenedor "caliente").
const s3 = new S3Client({});

const BUCKET = process.env.S3_BUCKET;
const PROCESSED_PREFIX = process.env.PROCESSED_PREFIX || "processed/";
const SIZE = 40;

// Máscara circular: blanco opaco dentro del círculo, transparente fuera.
// Con blend "dest-in" sharp conserva la imagen solo donde la máscara es opaca.
const CIRCLE_MASK = Buffer.from(
  `<svg width="${SIZE}" height="${SIZE}" xmlns="http://www.w3.org/2000/svg">` +
    `<circle cx="${SIZE / 2}" cy="${SIZE / 2}" r="${SIZE / 2}" fill="#fff"/>` +
    `</svg>`
);

// Convierte el Body de GetObject (un stream en Node.js) a Buffer.
async function bodyToBuffer(body) {
  if (typeof body.transformToByteArray === "function") {
    return Buffer.from(await body.transformToByteArray());
  }
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

// uploads/abc123.jpg -> processed/abc123_circular.png
function buildOutputKey(sourceKey) {
  const baseName = path.posix.basename(sourceKey, path.posix.extname(sourceKey));
  return `${PROCESSED_PREFIX}${baseName}_circular.png`;
}

// Recorta una imagen a círculo de 40x40 y la sube a processed/.
async function processImage(bucket, key) {
  console.log(`Procesando s3://${bucket}/${key}`);

  // 1. Leer la imagen original desde uploads/
  const original = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const input = await bodyToBuffer(original.Body);

  // 2. Transformar con sharp
  //    pages: 1 -> solo el primer cuadro si es un GIF animado
  //    fit "cover" -> rellena los 40x40 recortando lo que sobre (no deforma)
  //    ensureAlpha -> agrega canal alfa para poder tener transparencia
  //    composite dest-in -> deja visible solo la parte dentro del círculo
  const output = await sharp(input, { pages: 1 })
    .resize(SIZE, SIZE, { fit: "cover" })
    .ensureAlpha()
    .composite([{ input: CIRCLE_MASK, blend: "dest-in" }])
    .png()
    .toBuffer();

  // 3. Guardar el resultado en processed/
  const outputKey = buildOutputKey(key);
  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: outputKey,
      Body: output,
      ContentType: "image/png",
    })
  );

  console.log(`Imagen guardada en s3://${bucket}/${outputKey}`);
}

// Procesa un mensaje de SQS (una notificación de S3, que puede traer varias imágenes).
async function processRecord(record) {
  const notification = JSON.parse(record.body);

  // Al configurar la notificación, S3 envía un mensaje de prueba sin Records.
  // No es una imagen: lo damos por exitoso para que Lambda lo borre de la cola.
  if (notification.Event === "s3:TestEvent") {
    console.log(`Mensaje ${record.messageId}: s3:TestEvent ignorado`);
    return;
  }

  const s3Records = notification.Records || [];
  if (s3Records.length === 0) {
    console.log(`Mensaje ${record.messageId}: sin Records de S3, nada que procesar`);
    return;
  }

  for (const s3Record of s3Records) {
    // Las keys llegan codificadas como URL (los espacios vienen como "+").
    const key = decodeURIComponent(s3Record.s3.object.key.replace(/\+/g, " "));
    await processImage(BUCKET, key);
  }
}

exports.handler = async (event) => {
  const records = event.Records || [];
  console.log(`Lote recibido con ${records.length} mensaje(s)`);

  const batchItemFailures = [];

  // Cada mensaje tiene su propio try/catch: si uno falla, los demás siguen.
  for (const record of records) {
    try {
      await processRecord(record);
    } catch (err) {
      console.error(`Error procesando el mensaje ${record.messageId}:`, err);
      batchItemFailures.push({ itemIdentifier: record.messageId });
    }
  }

  console.log(
    `Lote terminado: ${records.length - batchItemFailures.length} OK, ${batchItemFailures.length} con error`
  );

  // Con ReportBatchItemFailures, Lambda borra de la cola los mensajes exitosos
  // y deja visibles otra vez solo los que aparecen aquí (para reintentarlos).
  return { batchItemFailures };
};
