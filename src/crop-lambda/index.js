const path = require("path");
const { S3Client, GetObjectCommand, PutObjectCommand } = require("@aws-sdk/client-s3");
const sharp = require("sharp");

const s3 = new S3Client({});

const BUCKET = process.env.S3_BUCKET;
const PROCESSED_PREFIX = process.env.PROCESSED_PREFIX || "processed/";
const SIZE = 40;

// Con blend "dest-in" solo queda visible la imagen dentro del círculo.
const CIRCLE_MASK = Buffer.from(
  `<svg width="${SIZE}" height="${SIZE}" xmlns="http://www.w3.org/2000/svg">` +
    `<circle cx="${SIZE / 2}" cy="${SIZE / 2}" r="${SIZE / 2}" fill="#fff"/>` +
    `</svg>`
);

async function bodyToBuffer(body) {
  if (typeof body.transformToByteArray === "function") {
    return Buffer.from(await body.transformToByteArray());
  }
  const chunks = [];
  for await (const chunk of body) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function buildOutputKey(sourceKey) {
  const baseName = path.posix.basename(sourceKey, path.posix.extname(sourceKey));
  return `${PROCESSED_PREFIX}${baseName}_circular.png`;
}

async function processImage(bucket, key) {
  console.log(`Procesando s3://${bucket}/${key}`);

  const original = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const input = await bodyToBuffer(original.Body);

  // pages: 1 toma solo el primer cuadro de un GIF animado.
  const output = await sharp(input, { pages: 1 })
    .resize(SIZE, SIZE, { fit: "cover" })
    .ensureAlpha()
    .composite([{ input: CIRCLE_MASK, blend: "dest-in" }])
    .png()
    .toBuffer();

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

async function processRecord(record) {
  const notification = JSON.parse(record.body);

  // Mensaje de prueba que S3 envía al configurar la notificación; no trae imagen.
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
    // S3 envía la key codificada como URL, con los espacios como "+".
    const key = decodeURIComponent(s3Record.s3.object.key.replace(/\+/g, " "));
    await processImage(BUCKET, key);
  }
}

exports.handler = async (event) => {
  const records = event.Records || [];
  console.log(`Lote recibido con ${records.length} mensaje(s)`);

  const batchItemFailures = [];

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

  // Lambda borra de la cola los mensajes exitosos y reintenta solo estos.
  return { batchItemFailures };
};
