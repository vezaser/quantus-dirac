# 📘 Quantus DIRAC — Instalator Node + Miner dla Ubuntu / Debian  
### **Wersja: `install_quantus_all_docker.sh`**

Ten instalator został przygotowany specjalnie dla systemów:

- **Ubuntu 20.04 / 22.04 / 24.04**
- **Debian 11+**
- **WSL2 Ubuntu**
- **Każdy Debian-based system z apt**

Instalator automatycznie:

- zainstaluje Docker + docker compose plugin  
- wygeneruje klucze (seed + addr), jeśli potrzebujesz  
- zbuduje lokalny obraz minera  
- stworzy `docker-compose.yml`  
- uruchomi node + miner  
- zrobi szybki health-check  

---

# 🚀 Instalacja jednym poleceniem

Uruchom:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vezaser/quantus-dirac/main/install_quantus_all_docker.sh)

