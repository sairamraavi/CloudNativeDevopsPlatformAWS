const { S3Client } = require('@aws-sdk/client-s3');

const buildAwsCredentials = () => {
  const accessKeyId = process.env.AWS_ACCESS_KEY_ID || process.env.AWS_KEY_ID;
  const secretAccessKey = process.env.AWS_SECRET_ACCESS_KEY || process.env.AWS_SECRET_KEY;

  if (accessKeyId && secretAccessKey) {
    return { accessKeyId, secretAccessKey };
  }

  return undefined;
};

const s3Client = new S3Client({
  region: process.env.AWS_REGION,
  credentials: buildAwsCredentials(),
});

const encodeS3Key = (key) =>
  key.split('/').map(encodeURIComponent).join('/');

const buildPublicUrl = (key) => {
  if (!key) {
    return null;
  }

  // Preserve legacy CDN or HTTP(S) URLs.
  if (/^https?:\/\//i.test(key)) {
    return key;
  }

  return `/api/streaming/thumbnails/${encodeS3Key(key)}`;
};

module.exports = {
  s3Client,
  buildPublicUrl,
};
