# Self-healing hardened images

When Red Hat publishes a new Red Hat Hardened Images base image, a pipeline on OpenShift rebuilds the
application, signs it, checks it and stages it by itself. Production changes only after one person
approves a pull request.
