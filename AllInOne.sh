#! /bin/bash

cd $HOME

# https://github.com/zyedidia/eget/releases/tag/v1.1.0 -> use eget will be better.
downloadRelease(){ 
  full_repo_name=$1
  release_name=$2  
  filename=$3 
  if curl -sL "https://api.github.com/repos/$full_repo_name/releases/latest" | \
     jq -r '.assets[].browser_download_url' | \
     grep -E $release_name | wget -c -O $filename -qi -; 
  then 
    echo "Downloaded release: $filename" 
  else 
    echo "Failed to download release: $filename" 
  fi 
}

installOhmyzsh() {
    chsh -s $(which zsh)
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-autosuggestions ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
    sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/g' ~/.zshrc
}

installRustScan() {
    echo "[+] download and install rustscan"
    pushd $HOME
    wget -c -O rustscan.deb https://github.com/RustScan/RustScan/releases/download/2.0.1/rustscan_2.0.1_amd64.deb && \
    dpkg -i rustscan.deb && rm rustscan.deb
    popd
}

installAptBasic() {
    echo "[+] All in one script for lazy guy like me :)"
    echo "[+] Ubuntu based system "

    echo "[+] basic update with apt" 
    apt-get update -y --fix-missing #  && apt-get upgrade -y && apt-get dist-upgrade -y

    echo "[+] instlal nmap sqlmap python3 pip and zsh byobu libpcap-dev"
    apt-get install nmap git zsh python3 python3-pip byobu

    echo "[+] install 7z utils"
    apt install p7zip p7zip-full p7zip-rar -y

    echo "[+] install wget jq curl unzip httpie "
    apt-get install wget jq curl unzip httpie -y
}


installRedTools() {
    echo "[+] downloading projectdiscovery pdtm manager"
    bin_path=$HOME/bin
    mkdir -p $bin_path
    pushd $bin_path
    downloadRelease "projectdiscovery/pdtm" "*linux_amd64.zip" "pdtm.zip"
    unzip pdtm.zip && rm *.md && chmod +x pdtm && rm pdtm.zip
    downloadRelease "zu1k/nali" "*linux-amd64.+gz$" "nali.gz"
    gzip -d nali.gz && chmod +x nali
    popd

    echo "[+] downloading frp chisel nps"
    proxy_path=$HOME/proxy
    mkdir -p $proxy_path
    pushd $proxy_path
    downloadRelease "fatedier/frp" "*linux_amd64.tar.gz" "frp_linux.tar.gz" 
    downloadRelease "fatedier/frp" "*windows_amd64.zip" "frp_windows.zip" 
    downloadRelease "jpillora/chisel" "*linux_amd64.gz" "chisel_linux.gz" 
    downloadRelease "jpillora/chisel" "*windows_amd64.gz" "chisel_windows.gz"
    popd 
}

enableByobu(){
    echo "[+] Enable byobu"
    byobu-enable
}
setupPath(){
    echo "[+] Add ~/bin to PATH variable"
    echo 'export PATH=~/bin:$PATH' >> ~/.zshrc
}

installAptBasic
installRustScan
installRedTools
installOhmyzsh
#enableByobu
setupPath
