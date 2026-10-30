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

  const cdnBase = process.env.AWS_CDN_URL?.replace(/\/$/, '');
  if (cdnBase) {
    return `${cdnBase}/${key}`;
  }

  const bucket = process.env.AWS_S3_BUCKET;
  const region = process.env.AWS_REGION;
  if (!bucket || !region) {
    return key;
  }

  return `https://${bucket}.s3.${region}.amazonaws.com/${key}`;
};

module.exports = {
  s3Client,
  buildPublicUrl,
};
