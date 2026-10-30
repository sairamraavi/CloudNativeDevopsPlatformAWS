variable "bucket_name" {
  description = "Globally unique bucket for temporary Ansible SSM transfers."
  type        = string
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
