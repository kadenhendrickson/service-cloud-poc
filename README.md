# Overview
This repository contains resources that DX Customer Engineers can use to help customers pilot Service Cloud/Scorecards. It includes:
- Terraform configurations for creating scorecards in a customer’s DX account
- A GitHub data collection script to populate DX with repo configuration data used by the GitHub scorecard

---

### Prerequisites
- Terraform installed
- For GitHub data collection:
  - Node.js 20+ and npm 10+
  - GitHub Personal Access Token (PAT) with scopes: Metadata: Read, Contents: Read, Administration: Read

---

### One-time setup per customer
1) Clear Terraform state (start clean for each customer)
   - Delete the following inside `terraform-scorecards/`:
     - `.terraform/` directory
     - `terraform.tfstate` (if present)
     - `terraform.tfstate.backup` (if present)
     - `terraform.lock.hcl` (if present)

2) Configure the customer’s DX API token
   - Option A (recommended): export an environment variable before running Terraform:

```bash
export DX_WEB_API_TOKEN="<customer_dx_web_api_token>"
```

   - Option B: set it directly in `terraform-scorecards/terraform.tf` under the `provider "dx"` block (`api_token = "..."`).
   - Required scopes for the token: `scorecards:read`, `scorecards:write`.

3) Initialize Terraform

```bash
cd terraform-scorecards
terraform init
```

---

### Creating a single scorecard
The `main.tf` contains multiple `dx_scorecard` resources. Use targeted apply to create only what the customer needs:

**SonarQube scorecard**

```bash
terraform apply -target=dx_scorecard.sonarqube_insights
```

**SonarCloud scorecard**

```bash
terraform apply -target=dx_scorecard.sonarcloud_insights
```
**Snyk Scorecard**
```bash
terraform apply -target=dx_scorecard.snyk_issues
```

**GitHub repo configuration scorecard**

```bash
terraform apply -target=dx_scorecard.github_repo_configuration
```

Notes:
- You can run `terraform plan -target=...` first to preview.
- `-target` ensures only that scorecard is created, leaving others untouched.
- You can run `terraform destroy -target=...` to delete the scorecard from the customer account if you need

---

### GitHub data collection (required for the GitHub scorecard)
The GitHub scorecard evaluates repo configuration signals (e.g., branch protection, README/CODEOWNERS). Populate these into DX first, using the collector in `github-data-collection/`. Detailed usage notes can be found in `github-data-collection/README.md`

Requirements:
- Environment variables

```bash
# GitHub PAT (required). Must have: Metadata: Read, Contents: Read, Administration: Read
export GITHUB_TOKEN="<your_github_pat>"

# Only required if writing directly to DX (output=dx)
export DX_URL="https://<your-dx-domain>"
export DX_API_KEY="<dx_data_cloud_api_token>"
```

Usage examples:
- CSV output (default). Customer should provide the output CSV with us to ingest into custom_data (TODO: Write ingestion script)

```bash
cd github-data-collection
npm ci
node github-data-collector.js --org <github_org> --output csv --csv ./github_data.csv
```

- Write directly to DX custom data (skips the CSV handoff)

```bash
cd github-data-collection
npm ci
node github-data-collector.js --org <github_org> --output dx
```

What it collects (per repo):
- README present and last commit timestamp
- CODEOWNERS present and last commit timestamp
- Branch protection settings on the default branch (admin enforcement, allow force pushes/deletions, lock branch, etc.)

After data is present in DX (either via `--output dx` or after DX ingests your CSV), create the GitHub scorecard:

```bash
cd ../terraform-scorecards
terraform apply -target=dx_scorecard.github_repo_configuration
```

---

### Tips and troubleshooting
- If Terraform errors about credentials, confirm the API token is set via `DX_WEB_API_TOKEN` or directly in `terraform.tf`.
- For GitHub:
  - 401/403: confirm `GITHUB_TOKEN` and required scopes; org SSO/IP policies may apply.
  - 404 on branch protection is expected if no rules exist on the default branch.
- Re-run `terraform init` after switching customers or if you cleared `.terraform/`.

---

### Quickstart (copy/paste)

```bash
# 1) Clean state
cd terraform-scorecards
rm -rf .terraform terraform.tfstate terraform.tfstate.backup terraform.lock.hcl

# 2) Set customer token (recommended via env)
export DX_WEB_API_TOKEN="<customer_dx_web_api_token>"

# 3) Init
terraform init

# 4) Create the scorecard needed for this customer (pick one)
terraform apply -target=dx_scorecard.sonarqube_insights
terraform apply -target=dx_scorecard.sonarcloud_insights
terraform apply -target=dx_scorecard.snyk_issues
terraform apply -target=dx_scorecard.github_repo_configuration
```
