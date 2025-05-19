variable "autoscaling_group_name" {
    description = "Name of the autoscaling group"
    type        = string
}

variable "load_balancer_url" {
    description = "Load balancer url"
    type        = string
}

variable "vpc_cidr" {
    description = "CIDR block for VPC"
    type        = string
    default     = "10.0.0.0/16"
}

variable "certificate_arn" {
    description = "ARN of ACM certificate for ALB"
    type        = string
}