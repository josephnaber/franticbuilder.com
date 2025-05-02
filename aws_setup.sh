#!/bin/bash

# ==== CONFIG ====
DOMAIN=${1:-franticbuilder.com}
REGION="us-east-1" # ACM cert MUST be in us-east-1 for CloudFront

echo "➡️ Using domain: $DOMAIN"

# Get the hosted zone ID automatically (must be an exact match)
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name $DOMAIN \
    --query "HostedZones[0].Id" \
    --output text)

if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" == "None" ]; then
    echo "❌ ERROR: Could not find hosted zone for $DOMAIN in Route 53."
    exit 1
fi

# Clean up zone ID (remove /hostedzone/ prefix)
HOSTED_ZONE_ID=${HOSTED_ZONE_ID##*/}

echo "✅ Found Hosted Zone ID: $HOSTED_ZONE_ID"

# ==== 1️⃣ Create S3 bucket ====
echo "➡️ Creating S3 bucket: $DOMAIN"
aws s3 mb s3://$DOMAIN

echo "➡️ Enabling static website hosting"
aws s3 website s3://$DOMAIN/ --index-document index.html

echo "➡️ Uploading index.html"
aws s3 cp index.html s3://$DOMAIN/

echo "➡️ Uploading images directory"
aws s3 cp images s3://$DOMAIN/images --recursive

echo "➡️ Applying public read bucket policy"
cat <<EOF > policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$DOMAIN/*"
    }
  ]
}
EOF

aws s3api put-bucket-policy --bucket $DOMAIN --policy file://policy.json

# ==== 2️⃣ Request SSL cert ====
echo "➡️ Requesting SSL certificate for $DOMAIN and *.$DOMAIN"
CERT_ARN=$(aws acm request-certificate \
    --domain-name $DOMAIN \
    --subject-alternative-names "*.$DOMAIN" \
    --validation-method DNS \
    --region $REGION \
    --output text \
    --query CertificateArn)

echo "✅ Certificate ARN: $CERT_ARN"

# ==== 3️⃣ Get DNS validation info ====
echo "➡️ Fetching DNS validation info for all domains..."
VALIDATION_OPTIONS=$(aws acm describe-certificate \
    --certificate-arn $CERT_ARN \
    --region $REGION \
    --query "Certificate.DomainValidationOptions" \
    --output json)

COUNT=$(echo $VALIDATION_OPTIONS | jq 'length')

for (( i=0; i<$COUNT; i++ ))
do
    DNS_NAME=$(echo $VALIDATION_OPTIONS | jq -r ".[$i].ResourceRecord.Name")
    DNS_TYPE=$(echo $VALIDATION_OPTIONS | jq -r ".[$i].ResourceRecord.Type")
    DNS_VALUE=$(echo $VALIDATION_OPTIONS | jq -r ".[$i].ResourceRecord.Value")
    DOMAIN_NAME=$(echo $VALIDATION_OPTIONS | jq -r ".[$i].DomainName")

    echo "✅ Adding DNS validation record for: $DOMAIN_NAME"
    echo "Type:  $DNS_TYPE"
    echo "Name:  $DNS_NAME"
    echo "Value: $DNS_VALUE"

    cat <<EOF > dns-validation.json
{
  "Comment": "Add ACM certificate DNS validation record for $DOMAIN_NAME",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DNS_NAME",
        "Type": "$DNS_TYPE",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "$DNS_VALUE"
          }
        ]
      }
    }
  ]
}
EOF

    aws route53 change-resource-record-sets \
        --hosted-zone-id $HOSTED_ZONE_ID \
        --change-batch file://dns-validation.json

    echo "✅ DNS validation record added for $DOMAIN_NAME."
done

# ==== 4️⃣ Wait for certificate to be issued ====
echo "⏳ Waiting for certificate to be ISSUED (this may take a few minutes)..."

while true; do
    STATUS=$(aws acm describe-certificate \
        --certificate-arn $CERT_ARN \
        --region $REGION \
        --query "Certificate.Status" \
        --output text)
    echo "   Current status: $STATUS"

    if [ "$STATUS" == "ISSUED" ]; then
        echo "🎉 Certificate ISSUED!"
        break
    elif [ "$STATUS" == "FAILED" ]; then
        echo "❌ Certificate request FAILED. Please check in AWS console."
        exit 1
    fi
    sleep 15
done

# ==== 5️⃣ Create CloudFront distribution ====

S3_WEBSITE_ENDPOINT="$DOMAIN.s3-website-$REGION.amazonaws.com"

echo "➡️ Creating CloudFront distribution configuration..."
cat <<EOF > cloudfront-config.json
{
  "CallerReference": "$(date +%s)",
  "Comment": "CloudFront distribution for $DOMAIN",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-$DOMAIN",
        "DomainName": "$S3_WEBSITE_ENDPOINT",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only"
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-$DOMAIN",
    "ViewerProtocolPolicy": "redirect-to-https",
    "TrustedSigners": {
      "Enabled": false,
      "Quantity": 0
    },
    "ForwardedValues": {
      "QueryString": false,
      "Cookies": {
        "Forward": "none"
      }
    },
    "MinTTL": 0,
    "DefaultTTL": 86400
  },
  "ViewerCertificate": {
    "ACMCertificateArn": "$CERT_ARN",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2019"
  },
  "Enabled": true,
  "Aliases": {
    "Quantity": 1,
    "Items": ["$DOMAIN"]
  }
}
EOF

echo "➡️ Creating CloudFront distribution..."
DIST_ID=$(aws cloudfront create-distribution \
    --distribution-config file://cloudfront-config.json \
    --query 'Distribution.Id' \
    --output text)

if [ -z "$DIST_ID" ]; then
    echo "❌ Failed to create CloudFront distribution. Please check the AWS CLI output above for errors."
    exit 1
fi

echo "✅ CloudFront distribution created with ID: $DIST_ID"

# ==== 6️⃣ Output next DNS step ====
echo "➡️ Fetching CloudFront domain name..."
DIST_DOMAIN=$(aws cloudfront get-distribution --id $DIST_ID --query "Distribution.DomainName" --output text)

echo "✅ CloudFront Domain: $DIST_DOMAIN"

# ==== 7️⃣ Create DNS A-record (ALIAS) for CloudFront ====
echo "➡️ Creating DNS A-record (ALIAS) for CloudFront..."
cat <<EOF > cloudfront-alias.json
{
  "Comment": "Create A-record (ALIAS) for CloudFront distribution",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "Z2FDTNDATAQYW2",
          "DNSName": "$DIST_DOMAIN",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF

aws route53 change-resource-record-sets \
    --hosted-zone-id $HOSTED_ZONE_ID \
    --change-batch file://cloudfront-alias.json

echo "✅ DNS A-record (ALIAS) created for CloudFront distribution"

echo "🎉 DONE! Your site is live (once DNS & CloudFront fully propagate, ~15-30 mins)."