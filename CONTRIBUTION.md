# Contributing to nostr_rpc

Thank you for your interest in contributing to `nostr_rpc`! This document outlines the process for developing new features, submitting pull requests, and releasing updates. It serves as a quick reference for the development workflow.

## Table of Contents
- [Contributing to nostr\_rpc](#contributing-to-nostr_rpc)
  - [Table of Contents](#table-of-contents)
  - [Setup](#setup)
  - [Developing a New Feature](#developing-a-new-feature)
  - [Pull Requests](#pull-requests)
  - [Release Process](#release-process)
  - [Branch Protection](#branch-protection)
  - [CI/CD Pipeline](#cicd-pipeline)

## Setup
1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/your-username/nostr_rpc.git
   cd nostr_rpc
   ```
3. Add the upstream remote:
   ```bash
   git remote add upstream https://github.com/j5s9/nostr_rpc.git
   ```
4. Install dependencies:
   ```bash
   dart pub get
   ```
5. Run tests to ensure everything works:
   ```bash
   dart test
   ```

## Developing a New Feature
Follow these steps to develop a new feature or bugfix:

1. **Create a feature or bugfix branch** from the main branch:
   ```bash
   git checkout main

   git checkout -b feature/your-feature-name
   git checkout -b bugfix/your-bugfix-name
   ```

2. **Develop your feature**:
   - Write code, add tests, update documentation.
   - Ensure all tests pass: `dart test`
   - Follow the code style (use `dart format` and `dart analyze` – the CI will check this automatically).

3. **Commit your changes**:
   ```bash
   git add .
   git commit -m "Add: Brief description of your feature"
   ```

4. **Push your branch**:
   ```bash
   git push -u origin feature/your-feature-name
   ```

5. **Create a Pull Request** to merge into `main` (see [Pull Requests](#pull-requests) below).

## Pull Requests
- **Target branch**: Always create PRs targeting the `main` branch.
- **Description**: Provide a clear description of what the PR does, why it's needed, and any breaking changes.
- **Reviews**: At least one review is required before merging.
- **Squash merge**: Use squash merging to keep the `main` branch history clean.
- **After merge**: Delete the feature branch.

## Release Process
When features in `main` are ready for release:

1. **Create a release branch** from `main`:
   ```bash
   git checkout main
   git pull upstream main  # Ensure up-to-date
   git checkout -b release/vX.Y.Z  # e.g., release/v1.0.0
   ```

2. **Prepare the release**:
   - Update version in `pubspec.yaml`.
   - Update changelog if applicable.
   - Run final tests: `dart test`
   - Dry-run publish: `dart pub publish --dry-run`

3. **Push the release branch**:
   ```bash
   git add .
   git commit -m "Release vX.Y.Z"
   git push -u origin release/vX.Y.Z
   ```

4. **Create a Pull Request** from `release/vX.Y.Z` to `release` (the protected release branch):
   - If `release` branch doesn't exist, create it first.
   - Squash all commits into one: "Release vX.Y.Z"
   - Wait for approval and merge.

5. **Publishing**:
   - Pushing to `release` triggers the CI/CD pipeline.
   - The pipeline publishes to pub.dev automatically.

6. **Post-release cleanup**:
   - Merge `release` back to `main` for clean history:
     ```bash
     git checkout main
     git merge release
     git push upstream main
     ```
   - Delete the temporary release branch: `git branch -d release/vX.Y.Z`

## Branch Protection
- **main**: Requires PR reviews, status checks (tests), restricts pushes.
- **release**: Only maintainers can push, requires PRs.

Set these up in Repository Settings > Branches > Add Rule.

## CI/CD Pipeline
- **Triggers**: Pushes to `main`, `release`; PRs to `main`.
- **Jobs**:
  - `test`: Runs on Ubuntu, installs Dart, checks code analysis (`dart analyze`), verifies formatting (`dart format`), and runs all tests.
  - `build-and-publish`: Only on `release` pushes, publishes to pub.dev.
- See `.github/workflows/ci-cd.yml` for details.

For questions or issues, open an issue on GitHub or contact the maintainers.
