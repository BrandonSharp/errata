# Consolidated Azure Inventory

This script came in handy to generate a consolidated inventory of Azure resources across multiple subscriptions. Uses `az` commands and `jq` to create a nicely formatted Markdown file.

Creates a table with resources and count, and then a more detailed breakdown by resource type of all the resources.