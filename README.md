# 🚀 Automated Dockerized Deployment Script (Stage 1 - DevOps Internship)

This project demonstrates a **production-grade Bash automation script** that sets up, deploys, and configures a **Dockerized Node.js application** on a **remote Ubuntu server (Azure VM)** with **Nginx reverse proxy**.  
It’s designed to be **idempotent**, meaning you can safely re-run it for updates without breaking existing setups.

---

## 🧠 What the Script Does

The `deploy.sh` script automates the entire DevOps deployment workflow:

1. **Collects Inputs**
   - Git repository URL  
   - GitHub Personal Access Token (optional for private repos)  
   - Branch name  
   - SSH username, host IP, and private key path  
   - Internal app port, remote directory, app name, and domain  

2. **Validates and Clones Repo**
   - Authenticates using PAT (if needed)  
   - Checks out the correct branch  
   - Verifies the presence of `Dockerfile` or `docker-compose.yml`

3. **Prepares Remote Environment**
   - Connects to the remote server via SSH  
   - Installs Docker, Docker Compose, and Nginx (if not already installed)  
   - Enables and starts all required services

4. **Transfers Code and Deploys**
   - Copies project files to the remote host  
   - Builds Docker image and runs the container  
   - Binds container port → 127.0.0.1:3000  

5. **Configures Nginx Reverse Proxy**
   - Creates `/etc/nginx/sites-available/app.conf`  
   - Proxies incoming HTTP traffic on port 80 → internal port 3000  
   - Tests configuration and reloads Nginx  

6. **Validates Deployment**
   - Checks Docker and Nginx status  
   - Confirms application is accessible via `curl`  
   - Outputs a success message and saves logs  

---

## 🖥️ Tech Stack

| Component | Description |
|------------|-------------|
| **Language** | Bash Script |
| **Web Server** | Nginx |
| **App Runtime** | Node.js |
| **Containerization** | Docker |
| **Platform** | Ubuntu (Azure VM) |
| **Version Control** | GitHub |

---

## ⚙️ How to Use

### 🧩 Prerequisites

- Ubuntu VM (local or cloud, e.g. Azure)
- SSH key pair generated and added to your VM
- Git installed locally
- (Optional) GitHub Personal Access Token if repo is private
- Port **80** open on your VM’s Network Security Group (NSG)

### 🔧 Steps to Run

1. Clone this repo and navigate into it:
   git clone https://github.com/abayomieodusanya/hng13-stage1-devops.git
   cd hng13-stage1-devops
Move or copy the deploy.sh script to your project folder. Make it executable: chmod +x deploy.sh Run the deployment: ./deploy.sh Provide the following details when prompted: GitHub repo URL PAT (leave blank if public) Branch (e.g. main) SSH username VM IP address SSH private key path (e.g. /home/user/.ssh/id_rsa) Internal app port (3000) Remote directory (e.g. /opt/app) App name (e.g. app) Domain (_ if none) Watch the script automatically: Install Docker, Nginx Build and run container Configure reverse proxy Validate everything Once done, open: http://<your-vm-public-ip>/ You should see: Hello from Node on port 3000 🧹 Cleanup (Optional) To remove all containers, images, and Nginx configuration related to the app: ./deploy.sh --cleanup 🪄 Logs and Files Deployment logs → logs/deploy_YYYYMMDD_HHMMSS.log App deployment → /opt/app on your VM Nginx config → /etc/nginx/sites-available/app.conf 🧾 Author Abayomi Odusanya DevOps & Cloud Support Engineer Azure | Linux | Automation | CI/CD | Docker | Nginx 📧 yommieodusanya@gmail.com 🌐 GitHub: abayomieodusanya 🌟 Outcome ✅ Fully automated CI/CD-style deployment ✅ Secure SSH-based connection ✅ Idempotent, repeatable builds ✅ Real-world demonstration of Bash + Docker + Nginx DevOps workflow ✅ Validated running app visible on browser This project demonstrates practical DevOps automation using real infrastructure. It’s ideal for portfolio showcasing, internship evaluation, and cloud deployment practice.
