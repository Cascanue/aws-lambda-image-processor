"use strict";

const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const busboy = require("busboy");
const { v4: uuidv4 } = require("uuid");

const s3 = new S3Client({});

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10 MB
const FILE_FIELD = "file";

const ALLOWED_MIME_TYPES = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/gif": "gif",
  "image/webp": "webp",
};
const ALLOWED_EXTENSIONS = ["jpg", "jpeg", "png", "gif", "webp"];

// Sin headers CORS: los agrega API Gateway.
function response(statusCode, body) {
  return {
    statusCode,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  };
}

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

function parseMultipart(body, contentType) {
  return new Promise((resolve, reject) => {
    let bb;
    try {
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
      // busboy trunca el archivo al superar fileSize en vez de fallar.
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
    if (!event.body) {
      return response(400, { error: "No se recibió ningún archivo" });
    }

    const contentType = (event.headers || {})["content-type"];
    if (!contentType) {
      return response(400, { error: "Falta el header content-type" });
    }

    // API Gateway entrega los cuerpos binarios en base64; busboy necesita los bytes reales.
    const body = event.isBase64Encoded
      ? Buffer.from(event.body, "base64")
      : Buffer.from(event.body);

    const file = await parseMultipart(body, contentType);

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
