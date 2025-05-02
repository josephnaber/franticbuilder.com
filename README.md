# AWS Website Deployment Scripts

This project provides a set of shell scripts to automate the deployment of a static website to AWS using S3, CloudFront, and Route 53. It handles everything from bucket creation to SSL certificate setup and DNS configuration.

## Prerequisites

- AWS CLI installed and configured
- A domain name registered in Route 53
- jq command-line tool installed
- Basic understanding of AWS services (S3, CloudFront, Route 53, ACM)

## Project Structure

- `commands.sh`: Main entry point for deployment
- `aws_setup.sh`: Core deployment script that handles all AWS resource creation and configuration
- `index.html`: Your website's main page
- `images/`: Directory containing website images

## Features

- Creates and configures an S3 bucket for static website hosting
- Sets up SSL certificate using AWS Certificate Manager
- Creates a CloudFront distribution with HTTPS support
- Configures DNS records in Route 53
- Automates the entire deployment process

## Usage

1. Configure your AWS credentials:
   ```bash
   export AWS_PROFILE=your_profile_name
   ```

2. Make the setup script executable:
   ```bash
   chmod +x aws_setup.sh
   ```

3. Run the deployment script:
   ```bash
   ./commands.sh
   ```

   By default, it will use the domain `franticbuilder.com`. To use a different domain, modify the command in `commands.sh`.

## What the Script Does

1. Creates an S3 bucket and enables static website hosting
2. Uploads your website files (index.html and images)
3. Applies a public read bucket policy
4. Requests an SSL certificate for your domain
5. Sets up DNS validation records
6. Creates a CloudFront distribution
7. Configures DNS A-record (ALIAS) for CloudFront

## Notes

- The script assumes your domain is already registered in Route 53
- SSL certificate validation may take a few minutes
- CloudFront distribution and DNS changes may take 15-30 minutes to fully propagate
- The script is configured for the `us-east-1` region (required for CloudFront)

## Troubleshooting

If you encounter any issues:
1. Check your AWS credentials and permissions
2. Verify your domain is properly configured in Route 53
3. Ensure all required AWS services are available in your region
4. Check the AWS CloudWatch logs for detailed error messages

## Security Considerations

- The S3 bucket is configured with public read access
- SSL/TLS is enforced through CloudFront
- Make sure to follow AWS security best practices for your specific use case

## License

This project is open source and available for use under the MIT License. 