# Uploading Your Local Directory to This Repository

Follow the steps below to replace the placeholder files in this repository with your **actual project directory**.

---

## Prerequisites

- [Git](https://git-scm.com/downloads) installed on your local machine
- Your Samba project files available locally (the directory you want to upload)

---

## Step-by-Step: Push Your Whole Directory

### 1. Open a terminal and navigate to your project directory

```bash
cd /path/to/your/samba-project
```

Replace `/path/to/your/samba-project` with the actual path on your machine
(e.g. `cd ~/Documents/Samba-Server-File-Share-Simulation`).

---

### 2. Initialize a Git repository (if you haven't already)

```bash
git init
```

> Skip this step if there is already a `.git` folder inside your project directory.

---

### 3. Connect to this GitHub repository

```bash
git remote add origin https://github.com/jesseash/Samba-Server-File-Share-Simulation.git
```

> If you already added a remote called `origin`, check with `git remote -v`.
> If it points somewhere else, update it:
> ```bash
> git remote set-url origin https://github.com/jesseash/Samba-Server-File-Share-Simulation.git
> ```

---

### 4. Fetch the existing branch

```bash
git fetch origin
```

---

### 5. Switch to the PR branch

```bash
git checkout -b copilot/create-repo-with-file-structure --track origin/copilot/create-repo-with-file-structure
```

> If Git says the branch already exists locally, run:
> ```bash
> git checkout copilot/create-repo-with-file-structure
> git pull origin copilot/create-repo-with-file-structure
> ```

---

### 6. Stage all your project files

```bash
git add .
```

This stages every file and folder inside your current directory.

---

### 7. Commit

```bash
git commit -m "Upload complete Samba project directory"
```

---

### 8. Push to GitHub

```bash
git push origin copilot/create-repo-with-file-structure
```

You will be prompted for your GitHub username and a
[Personal Access Token](https://github.com/settings/tokens) (use a token instead of your password).

---

## After Pushing

Once the push completes, your files will appear in the PR branch on GitHub. You can then leave a comment on the PR asking Copilot to reorganize or clean up the structure, or simply merge the branch directly.

---

## Need Help?

- [GitHub Docs – Adding a local repository to GitHub using Git](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)
- [Create a Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
