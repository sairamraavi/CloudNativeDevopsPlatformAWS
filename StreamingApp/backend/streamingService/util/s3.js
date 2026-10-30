const { S3Client } = require('@aws-sdk/client-s3');

// Use the AWS SDK default credential provider chain.
// EKS workloads receive temporary credentials through Pod Identity.
const s3Client = new S3Client({
  region: process.env.AWS_REGION,
});

const buildPublicUrl = (key) => {
  if (!key) {
    return null;
  }

  if (/^https?:\/\//i.test(key)) {
    return key;
  }

  const base = process.env.STREAMING_PUBLIC_URL?.replace(/\/$/, '') || 'http://localhost:3002';
  return `${base}/api/streaming/thumbnails/${encodeURI(key)}`;
};

const buildStreamUrl = (videoId) => {
  const base = process.env.STREAMING_PUBLIC_URL?.replace(/\/$/, '');
  const path = `/api/streaming/stream/${videoId}`;
  if (!base) {
    return path;
  }
  return `${base}${path}`;
};

module.exports = {
  s3Client,
  buildPublicUrl,
  buildStreamUrl,
};
