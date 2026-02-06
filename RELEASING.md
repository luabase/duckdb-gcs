# Releasing Guide

This document describes how to create a new release of the DuckDB GCS extension.

## Automatic Release (Recommended)

The easiest way to create a release is using GitHub's release interface, which triggers the automated build:

### 1. Prepare the Release

```bash
# Make sure your code is ready
git status

# Make sure all tests pass
make test
make unittest

# Commit any final changes
git add .
git commit -m "Prepare for release v1.0.0"
git push origin main
```

### 2. Create a GitHub Release

1. **Go to your repository's releases page:**
   ```
   https://github.com/northpolesec/duckdb-gcs/releases
   ```

2. **Click "Draft a new release"**

3. **Fill in the release details:**
   - **Tag**: Create a new tag (e.g., `v1.0.0`)
   - **Target**: `main` branch
   - **Release title**: `v1.0.0` or `DuckDB GCS Extension v1.0.0`
   - **Description**: Add release notes, what's new, etc.

4. **Publish the release**
   - Click "Publish release" (not "Save draft")
   - This triggers the GitHub Actions workflow

### 3. Wait for GitHub Actions

The workflow will automatically:
- Build extension binaries for all platforms:
  - Linux AMD64
  - Linux ARM64
  - macOS Intel (AMD64)
  - macOS Apple Silicon (ARM64)
- Run tests on each platform
- Upload all binaries to the release

You can monitor progress at:
```
https://github.com/northpolesec/duckdb-gcs/actions
```

### 4. Verify the Release

Once complete, check the release at:
```
https://github.com/northpolesec/duckdb-gcs/releases
```

Test the installation:
```bash
duckdb -unsigned
```

```sql
INSTALL gcs FROM 'https://github.com/northpolesec/duckdb-gcs/releases/download/v1.0.0';
LOAD gcs;
SELECT * FROM read_parquet('gs://your-test-bucket/test.parquet') LIMIT 1;
```

## Manual Trigger

You can also manually trigger a release build for an existing release:

1. Go to https://github.com/northpolesec/duckdb-gcs/actions
2. Select "Release Extension" workflow
3. Click "Run workflow"
4. Enter the version tag (e.g., `v1.0.0`)
5. Click "Run workflow"

This is useful if the initial build failed or you need to rebuild for any reason.

## Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **Major version** (v2.0.0): Breaking changes
- **Minor version** (v1.1.0): New features, backwards compatible
- **Patch version** (v1.0.1): Bug fixes, backwards compatible

### When to Bump Versions

- **Patch** (v1.0.1): Bug fixes, performance improvements, documentation updates
- **Minor** (v1.1.0): New features, new configuration options (backwards compatible)
- **Major** (v2.0.0): Breaking API changes, major refactoring, incompatible changes

## DuckDB Version Compatibility

Each release is built against a specific DuckDB version (currently v1.4.2).

If you need to support multiple DuckDB versions:

1. Update `.github/workflows/Release.yml` to include multiple build jobs
2. Build against each DuckDB version
3. Organize releases by DuckDB version

Example structure:
```
v1.0.0/
├── duckdb-v1.4.2/
│   ├── linux_amd64/
│   └── osx_arm64/
└── duckdb-v1.5.0/
    ├── linux_amd64/
    └── osx_arm64/
```

## Custom Repository Setup (Advanced)

If you want to host extensions on your own infrastructure (S3, GCS, etc.):

### 1. Build the Extensions

Use the GitHub Actions artifacts or build locally for each platform.

### 2. Organize Repository Structure

```bash
# Use the provided script
./scripts/organize_repository.sh v1.0.0 v1.4.2

# This creates:
repository/
└── v1.4.2/
    ├── linux_amd64/
    │   └── gcs.duckdb_extension.gz
    ├── linux_arm64/
    │   └── gcs.duckdb_extension.gz
    ├── osx_amd64/
    │   └── gcs.duckdb_extension.gz
    └── osx_arm64/
        └── gcs.duckdb_extension.gz
```

### 3. Upload to Your Server

#### S3:
```bash
aws s3 sync repository/ s3://your-extension-bucket/ --acl public-read
```

#### GCS:
```bash
gsutil -m cp -r repository/* gs://your-extension-bucket/
gsutil -m acl ch -r -u AllUsers:R gs://your-extension-bucket
```

#### HTTP Server:
```bash
rsync -avz repository/ user@your-server:/var/www/extensions/
```

### 4. Users Install From Your Repository

```sql
-- Set custom repository
SET custom_extension_repository='https://your-extension-bucket.s3.amazonaws.com';

-- Install extension
INSTALL gcs;
LOAD gcs;
```

## Troubleshooting

### Build Fails on CI

1. Check the GitHub Actions logs
2. Look for vcpkg dependency issues
3. Verify DuckDB version compatibility
4. Test the build locally first

### Extension Won't Load

1. Verify DuckDB version matches (extension is for v1.4.2)
2. Check platform architecture matches
3. Ensure `-unsigned` flag is used
4. Check file isn't corrupted (re-download)

### Missing Platforms

If a platform build fails or is missing:

1. Check `.github/workflows/Release.yml` for excluded architectures
2. Some platforms (Windows) are excluded due to GCS SDK limitations
3. Add platforms by removing them from `exclude_archs`

## Release Checklist

Before creating a release:

- [ ] All tests pass locally (`make test && make unittest`)
- [ ] Code quality checks pass (`make format`)
- [ ] Update CHANGELOG.md (if present)
- [ ] Update version in documentation
- [ ] Commit and push all changes
- [ ] Create and push version tag
- [ ] Wait for CI to complete
- [ ] Test installation from release
- [ ] Update release notes if needed
- [ ] Announce release (if applicable)

## Support

If you encounter issues with the release process:

1. Check existing GitHub Issues
2. Review GitHub Actions logs
3. Create a new issue with:
   - Steps to reproduce
   - Error messages
   - CI logs (if applicable)
