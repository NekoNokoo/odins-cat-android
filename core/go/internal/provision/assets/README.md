# Provisioning assets

This directory is reserved for deploy-time assets that the Go core will upload or template.

Planned contents:

- shell scripts for remote host preparation
- xray service templates
- vk-turn-proxy service templates
- uninstall scripts
- health-check scripts

The first real implementation step will move deployment logic out of hardcoded strings and into these versioned assets.

