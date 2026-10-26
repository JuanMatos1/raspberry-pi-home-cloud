# JuanCloud Portfolio Evidence Guide

## How to review the project

1. Read [the monitoring architecture](monitoring-and-maintenance.md) and the root README.
2. Inspect `dashboard/` for the live metrics UI and Express API, and `monitoring/` for Python health rules and tests.
3. Review the changelog and commit history for the project evolution.
4. Verify automated update decisions are separated from human-reviewed container upgrades.

## Screenshots from the actual deployed server

![Live JuanCloud dashboard](../images/screenshots/juancloud-v2-dashboard.png)

![Real Gmail update-notification test](../images/screenshots/juancloud-update-email.png)

These are the author's actual uploaded screenshots, not generated examples. The email shows a **test notification**, not a confirmed installation event. Its Gmail account address is visible; redact or approve that disclosure before public release. In the dashboard capture, the AI answer mentions four pending packages while the verified metrics report zero. Trust the deterministic measurement; the discrepancy is an example of why the model is not used to make alert decisions.

Additional optional evidence: `unattended-upgrade --dry-run -v` and `apt-daily` timer output, sanitized to avoid private identifiers.

## Example recruiter-friendly project summary

> Expanded a Raspberry Pi 5 private-cloud environment into a monitored home server by combining deterministic Python health checks, a Node.js/Express dashboard, a local Ollama explanation layer, Gmail health notifications, and scheduled Ubuntu maintenance. Built the observability layer to separate measured facts from AI-generated explanations and to keep package upgrades and reboots under explicit operational controls.

## Integrity note

The code in this repository is a snapshot. Individual deployment steps must be verified on the running server. Do not claim end-to-end update-notifier delivery, restored backups or zero downtime without evidence.
