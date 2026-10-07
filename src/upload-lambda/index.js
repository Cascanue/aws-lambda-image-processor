"use strict";

// upload-lambda: tramo "API Gateway -> upload-lambda -> S3 (uploads/)" del diagrama.
// Recibe un multipart/form-data desde POST /upload, valida la imagen y la deja en
// el bucket bajo uploads/. Desde ahí la notificación S3 -> SQS dispara la crop-lambda.

const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const busboy = require("busboy");
const { v4: uuidv4 } = require("uuid");

// El cliente se crea fuera del handler para reutilizarlo entre invocaciones.
// Como la Lambda vive en subredes privadas, el tráfico a S3 sale por el S3 Gateway Endpoint.
const s3 = new S3Client({});

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 MB
const FILE_FIELD = "file";

// Tipos MIME permitidos y la extensión con la que se guarda cada uno.
const ALLOWED_MIME_TYPES = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/gif": "gif",
  "image/webp": "webp",
};
const ALLOWED_EXTENSIONS = ["jpg", "jpeg", "png", "gif", "webp"];

// Respuesta JSON para API Gateway HTTP API (payload 2.0). Sin headers CORS:
// de eso se encarga la cors_configuration del API en upload.tf.
function response(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

// Error con código HTTP asociado, para distinguir errores del cliente de los inesperados.
class HttpError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.statusCode = statusCode;
  }
}

function getExtension(filename) {
  if (!filename || !filename.includes(".")) return "";
  return filename.split(".").pop().toLowerCase();
}

// Parsea el cuerpo multipart con busboy y devuelve el archivo del campo "file".
function parseMultipart(body, contentType) {
  return new Promise((resolve, reject) => {
    let bb;
    try {
      // busboy lanza una excepción si el content-type no es multipart o no tiene boundary.
      bb = busboy({
        headers: { "content-type": contentType },
        limits: { files: 1, fileSize: MAX_FILE_SIZE },
      });
    } catch (err) {
      reject(new HttpError(400, "El cuerpo no es multipart/form-data válido"));
      return;
    }

    let fileData = null;
    let rejection = null;

    bb.on("file", (fieldname, stream, info) => {
      const { filename, mimeType } = info;

      // Solo nos interesa el campo "file"; cualquier otro se descarta.
      if (fieldname !== FILE_FIELD) {
        stream.resume();
        return;
      }

      const extension = getExtension(filename);
      if (!ALLOWED_MIME_TYPES[mimeType] || !ALLOWED_EXTENSIONS.includes(extension)) {
        rejection = new HttpError(
          415,
          "Tipo de archivo no permitido. Usa jpg, jpeg, png, gif o webp"
        );
        stream.resume(); // hay que consumir el stream para que busboy termine
        return;
      }

      const chunks = [];
      let truncated = false;

      stream.on("data", (chunk) => chunks.push(chunk));
      // "limit" se emite cuando el archivo supera limits.fileSize: busboy lo trunca.
      stream.on("limit", () => {
        truncated = true;
      });
      stream.on("end", () => {
        if (truncated || stream.truncated) {
          rejection = new HttpError(413, "El archivo supera el límite de 10 MB");
          return;
        }
        fileData = {
          buffer: Buffer.concat(chunks),
          mimeType,
          extension: ALLOWED_MIME_TYPES[mimeType],
        };
      });
    });

    bb.on("error", () => {
      reject(new HttpError(400, "El cuerpo no es multipart/form-data válido"));
    });

    bb.on("close", () => {
      if (rejection) return reject(rejection);
      if (!fileData || fileData.buffer.length === 0) {
        return reject(new HttpError(400, `No se recibió ningún archivo en el campo "${FILE_FIELD}"`));
      }
      resolve(fileData);
    });

    bb.end(body);
  });
}

exports.handler = async (event) => {
  try {
    // Sin body no hay nada que procesar.
    if (!event.body) {
      return response(400, { error: "No se recibió ningún archivo" });
    }

    // HTTP API entrega los headers en minúsculas.
    const contentType = (event.headers || {})["content-type"];
    if (!contentType) {
      return response(400, { error: "Falta el header content-type" });
    }

    // Los cuerpos binarios llegan codificados en base64; hay que decodificarlos
    // para que busboy reciba los bytes reales de la imagen.
    const body = event.isBase64Encoded
      ? Buffer.from(event.body, "base64")
      : Buffer.from(event.body);

    const file = await parseMultipart(body, contentType);

    // Key final: uploads/<uuid>.<ext>. El prefijo uploads/ es el que escucha la
    // notificación S3 -> SQS y el único donde el rol IAM permite escribir.
    const key = `${process.env.UPLOAD_PREFIX}${uuidv4()}.${file.extension}`;

    await s3.send(
      new PutObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: key,
        Body: file.buffer,
        ContentType: file.mimeType,
      })
    );

    return response(201, { key });
  } catch (err) {
    if (err instanceof HttpError) {
      return response(err.statusCode, { error: err.message });
    }
    console.error("Error inesperado al subir la imagen:", err);
    return response(500, { error: "Error interno del servidor" });
  }
};
