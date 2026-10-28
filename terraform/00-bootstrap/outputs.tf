output "state_bucket" {
  description = "S3 bucket holding remote state. Feed this to the 10-cluster and 20-inference backend blocks."
  value       = aws_s3_bucket.this.id
}

output "region" {
  description = "Region the state bucket lives in."
  value       = var.region
}

output "backend_config" {
  description = "Paste-ready backend block for the downstream layers."

  value = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.this.id}"
        key          = "<layer>/terraform.tfstate"
        region       = "${var.region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}
