# GitHub Data Collector

Collects repository metadata for a GitHub organization and outputs either:
- **CSV**: a flat file with columns for README/CODEOWNERS presence and branch protection settings
- **DX**: writes the same data into DX Data Cloud custom_data table for each repo

### What it collects
- **README.md**: whether it exists at the repo root and the last commit timestamp to that file
- **CODEOWNERS**: searches `.github/CODEOWNERS` then `CODEOWNERS` in the root; records presence and last commit timestamp
- **Branch protection** (for the repo’s default branch): admin enforcement, linear history, allow force pushes/deletions, block creations, required conversation resolution, lock branch, allow fork syncing, required PR reviews (object), required status checks (object)

---

## Requirements
- **Node.js** >= 20 and **npm** >= 10
- **GitHub token** (Personal Access Token) with the following permissions:
  - Metadata: Read
  - Contents: Read
  - Administration: Read (needed to read branch protection)

If using `--output=dx` you also need:
- **DX_URL**: Base URL for your DX instance (e.g., `https://app.getdx.com` or your vanity domain)
- **DX_API_KEY**: A DX Data Cloud API token (Settings > Data Cloud API)

---

## Install
From this directory:

```bash
cd "POC Data Collection"
npm install
# or for clean, reproducible installs
npm ci
```

---

## Environment variables
Set these in your shell before running:

```bash
export GITHUB_TOKEN="XXXXXXXXXXXXXXXXXXXXXXXX"

# Only required when --output=dx
export DX_URL="https://your-dx-domain"
export DX_API_KEY="XXXXXXXXXXXXXXXXXXXXXXXX"
```

On macOS with zsh (default), add them to `~/.zshrc` if you want them to persist across sessions.

---

## Usage
You can run the script directly with Node or via the npm script.

### CLI options
- `--org <string>`: GitHub organization to scan (required)
- `--output <dx|csv>`: Output mode; `csv` (default) or `dx`
- `--pageSize <number>`: Max results per GitHub API page (default: 1000)
- `--csv <path>`: CSV output path when `--output=csv` (default: `github_data.csv`)

Note: GitHub may cap `per_page` below very large values; the script requests your provided `--pageSize`.

### Run with Node
```bash
node github-data-collector.js --org your-org --output csv
```

## Examples
### 1) CSV to default path
```bash
node github-data-collector.js --org your-org --output csv
# writes ./github_data.csv
```

### 2) CSV to a custom file
```bash
node github-data-collector.js --org your-org --output csv --csv ./out/your_org_repos.csv
```

### 3) Send to DX Data Cloud
```bash
export DX_URL="https://your-dx-domain"
export DX_API_KEY="dx_api_XXXXXXXXXXXXXXXXXXXXXXXX"
node github-data-collector.js --org your-org --output dx
```

---

## CSV schema
The file includes the following columns:

```text
repo_full_name,repo_id,readme_root_exists,readme_root_last_commit_timestamp,codeowners_exists,codeowners_file_last_commit_timestamp,branch_protection_enforce_admins,branch_protection_linear_history,branch_protection_allow_force_pushes,branch_protection_allow_deletions,branch_protection_block_creations,branch_protection_required_conversation_resolution,branch_protection_lock_branch,branch_protection_allow_fork_syncing,branch_protection_required_pr_reviews,branch_protection_required_status_checks
```

Notes:
- `branch_protection_required_pr_reviews` and `branch_protection_required_status_checks` are JSON objects as strings in the CSV.
- Timestamps are ISO 8601 strings from the last commit touching the specific file.

---

## Troubleshooting
- **401/403 from GitHub**: Verify `GITHUB_TOKEN` is set and has the listed permissions. Organization SSO or IP allowlists can also block access.
- **404 for branch protection**: This is normal if the default branch has no protection rules.
- **DX 401/403**: Verify `DX_URL` and `DX_API_KEY` are correct and that your token has Data Cloud API access.
- **Rate limits**: The GitHub Search API and repo APIs are rate-limited. Wait and retry, or use a higher-privileged token where appropriate.



