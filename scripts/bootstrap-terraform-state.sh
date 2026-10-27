#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <globally-unique-s3-bucket-name> <aws-region>" >&2
  exit 2
fi

bucket=$1
region=$2

for command in aws; do
  command -v "$command" >/dev/null || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || {
  echo "Bucket name must be a valid lowercase S3 bucket name." >&2
  exit 2
}

account_id=$(aws sts get-caller-identity --query Account --output text)
if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
  echo "Bucket already exists and is accessible. Applying secure settings."
else
  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "$bucket" \
      --region "$region" \
      --create-bucket-configuration "LocationConstraint=$region" >/dev/null
  fi
fi

aws s3api put-bucket-ownership-controls \
  --bucket "$bucket" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-public-access-block \
  --bucket "$bucket" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning \
  --bucket "$bucket" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption \
  --bucket "$bucket" \
  --server-side-encryption-configuration \
  'Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]'
aws s3api put-bucket-policy \
  --bucket "$bucket" \
  --policy "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Sid\":\"DenyInsecureTransport\",
      \"Effect\":\"Deny\",
      \"Principal\":\"*\",
      \"Action\":\"s3:*\",
      \"Resource\":[\"arn:aws:s3:::$bucket\",\"arn:aws:s3:::$bucket/*\"],
      \"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}
    }]
  }"

echo "Terraform state bucket is configured: s3://$bucket (account $account_id, $region)."
echo "Grant only the Terraform deployment role access to this bucket and its lock file."
