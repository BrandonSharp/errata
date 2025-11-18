# Trivy Scan for Helm Charts

Had a need to scan all the images in a Helm chart for CVEs. This script should excise the images from a provided Helm chart + values file, then do a quick and dirty `trivy` scan against each, placing outputs in a directory.

Figured I'd throw some SBOM generation in while I was at it, so those outputs are generated as well.

To cap it off, I then generated a few reports in MD format to make it all consumable. Not sure how useful the "version conflicts" report will be in practice, but seems useful in finding some areas to optimize and standardize on library versions (e.g., if you're on `v1.2` of a dependency for most of your images, but one image is stuck on `v1.0`, this report will highlight that.).