## POC Scorecards - Provisioning Guide

This folder contains three `dx_scorecard` resources in `POC Scorecards/main.tf`:

- `dx_scorecard.production_readiness_example` (Production Readiness - POC READY)
- `dx_scorecard.sonarqube_insights` (SonarQube Insights)
- `dx_scorecard.sonarcloud_insights` (SonarCloud Insights)

The instructions below help you provision these one at a time.

### Prerequisites
- Terraform v1.x installed
- A DX Web API token with scopes: `scorecards:read` and `scorecards:write`

### 1) Change to this directory

```bash
cd "/Users/kaden/Documents/DX Scripts/terraform_examples/POC Scorecards"
```

### 2) Configure the DX provider token

Recommended: set the environment variable (avoids committing secrets):

```bash
export DX_WEB_API_TOKEN="YOUR_DX_TOKEN"
```

Alternatively, update the inline `api_token` in `terraform.tf` (not recommended for long-term):

### 3) (Optional) Update the provider version

Best practice: pin to a compatible range and update occasionally, not every run. This repo pins the provider in `POC Scorecards/terraform.tf`:

```hcl
terraform {
  required_providers {
    dx = {
      source  = "get-dx/dx"
      version = "0.3.1"   # example present in this folder
    }
  }
}
```

You can:
- Keep a compatible constraint (e.g., `~> 0.3.2`) to receive patch updates, then run `terraform init -upgrade`.
- Or bump to an exact newer version.

Commands:

```bash
# Option A: bump to a compatible series (example to ~> 0.3.2)
sed -i '' -E 's/(version\\s*=\\s*").*(")/\\1~> 0.3.2\\2/' "terraform.tf"

# Option B: pin to an exact version (example to 0.3.2)
sed -i '' -E 's/(version\\s*=\\s*").*(")/\\10.3.2\\2/' "terraform.tf"

# Refresh plugins and lockfile per the new constraint
terraform init -upgrade
```

Tip: Use `terraform providers lock -platform=darwin_amd64 -platform=darwin_arm64 -platform=linux_amd64` if you need a multi-platform lockfile.

### 4) Initialize Terraform (first time or after provider changes)

```bash
terraform init
```

### 5) Create resources one at a time

Each resource can be planned/applied individually using `-target`:

1) Production Readiness scorecard

```bash
terraform plan  -target=dx_scorecard.production_readiness_example
terraform apply -target=dx_scorecard.production_readiness_example -auto-approve
```

2) SonarQube Insights scorecard

```bash
terraform plan  -target=dx_scorecard.sonarqube_insights
terraform apply -target=dx_scorecard.sonarqube_insights -auto-approve
```

3) SonarCloud Insights scorecard

```bash
terraform plan  -target=dx_scorecard.sonarcloud_insights
terraform apply -target=dx_scorecard.sonarcloud_insights -auto-approve
```

Notes:
- `-target` is useful for incremental or selective applies. Once you’re done, you can run a normal `terraform plan` and `terraform apply` to reconcile the full desired state.
- If a target already exists, Terraform will show “no changes” for that target.

### 6) Verify

```bash
terraform state list | sort
```

You should see the addresses you applied (e.g., `dx_scorecard.production_readiness_example`, etc.).

### 7) (Optional) Destroy a single resource

```bash
terraform destroy -target=dx_scorecard.production_readiness_example -auto-approve
```

### Troubleshooting
- Token/auth errors: ensure `DX_WEB_API_TOKEN` is set and has `scorecards:read` and `scorecards:write` scopes.
- Provider version conflicts: update the version in `terraform.tf`, then run `terraform init -upgrade`.
- Concurrent state: avoid running multiple applies in parallel against the same directory/state.

