# tflint-ignore: terraform_unused_declarations
variable "region" {

  type        = string
  description = "OBSOLETE (not needed): AWS Region"
  default     = "us-east-1"
}