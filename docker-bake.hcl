variable "VERSION" { default = "latest" }
variable "REGISTRY" { default = "ghcr.io" }
variable "IMAGE_NAME" { default = "magmamoose/harddisk-hoover" }
variable "PLATFORMS" { default = "linux/amd64,linux/arm64" }

group "default" {
  targets = ["app"]
}

target "app" {
  context    = "."
  dockerfile = "Dockerfile"
  platforms  = split(",", PLATFORMS)
  tags       = ["${REGISTRY}/${IMAGE_NAME}:${VERSION}"]
}
