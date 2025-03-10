terraform {
  required_providers {
    okta = {
      source  = "okta/okta"
      version = "4.14.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.3.2"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "5.89.0"
    }
    time = {
      source = "hashicorp/time"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.0.1"
    }
  }
}


