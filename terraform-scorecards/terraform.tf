terraform {
  required_providers {
    dx = {
      source  = "get-dx/dx"
      version = "~>0.4.0"
    }
  }
}

provider "dx" {
  # Define your Web API token here, or set `DX_WEB_API_TOKEN` in your environment.
  #
  # To manage scorecards, the token must have the following scopes:
  #
  # - scorecards:read
  # - scorecards:write
  #
  api_token = ""
}