# 🔐 Verificação de Integridade do Pendrive no Windows

Este tutorial descreve, passo a passo, como um usuário pode verificar no **Windows** se um pendrive corresponde exatamente aos **checksums gerados pelo script em Linux**, garantindo que o dispositivo **não foi alterado ou corrompido**.

---

## 🎯 Objetivo

Validar que o conteúdo do pendrive é **bit a bit idêntico** ao estado original certificado, utilizando os hashes:

- SHA-256
- SHA-512
- BLAKE2b

---

## ⚠️ Pré-requisitos

Antes de começar, você precisa:

- ✔️ Arquivo de relatório gerado pelo script (ex: `sdb.hash-report.txt` encontrado no diretório `devices/pendriveX` onde X é o número da pendrive)
- ✔️ Arquivo de assinatura GPG (ex: `sdb.hash-report.txt.asc` encontrado no diretório `devices/pendriveX` onde X é o número da pendrive)
- ✔️ Chave pública GPG do autor (arquivo `marcosdecarvalho_publickey.asc` encontrado no diretório `public_keys`)
- ✔️ Acesso ao pendrive no Windows
- ✔️ Permissão de administrador

---

## 🧰 Ferramentas necessárias

### 1. Instalar Gpg4win (GPG no Windows)

Download oficial:

```
https://www.gpg4win.org/download.html
```

Instale com as opções padrão.

---

### 2. Instalar uma ferramenta de hash de disco bruto

O Windows não possui suporte nativo simples para hash de dispositivos inteiros. Use:

#### Opção recomendada: HashMyFiles (NirSoft)

Download:

```
https://www.nirsoft.net/utils/hash_my_files.html
```

⚠️ Execute como **Administrador**

---

## 🔑 Etapa 1: Verificar assinatura GPG

### Importar chave pública

```powershell
gpg --import publickey.asc
```

### Verificar assinatura do relatório

```powershell
gpg --verify sdb.hash-report.txt.asc sdb.hash-report.txt
```

### Resultado esperado:

```text
Good signature from "<autor> <email>"
```

✔️ Isso garante que o relatório não foi alterado.

---

## 🔍 Etapa 2: Identificar o pendrive no Windows

Abra o PowerShell como administrador:

```powershell
Get-Disk
```

Exemplo de saída:

```text
Number Friendly Name      Size
------ --------------     -----
2      USB Flash Disk     3.75 GB
```

⚠️ Anote o número do disco (ex: `2`)

---

## ⚠️ Etapa 3: Criar imagem RAW do dispositivo

O Windows não permite hashing direto fácil de `/dev/sdX`, então precisamos criar uma imagem.

### Usando `dd` para Windows (recomendado)

Download:

```
http://www.chrysocome.net/dd
```

### Comando:

```powershell
dd if=\\.\PhysicalDrive2 of=pendrive.img bs=4M
```

Substitua `2` pelo número correto do disco.

⚠️ Isso pode levar vários minutos.

---

## 🧮 Etapa 4: Calcular hashes no Windows

### SHA-256 (nativo)

```powershell
Get-FileHash pendrive.img -Algorithm SHA256
```

### SHA-512

```powershell
Get-FileHash pendrive.img -Algorithm SHA512
```

---

## 🧪 Etapa 5: BLAKE2b (opcional)

O Windows não possui suporte nativo. Use:

### Opção: OpenSSL

Download:

```
https://slproweb.com/products/Win32OpenSSL.html
```

Comando:

```powershell
openssl dgst -blake2b512 pendrive.img
```

---

## 📊 Etapa 6: Comparar com o relatório original

Abra o arquivo:

```
sdb.hash-report.txt
```

Procure por:

```text
SHA-256: <valor>
SHA-512: <valor>
BLAKE2b: <valor>
```

Compare manualmente com os valores calculados.

✔️ Se todos coincidirem → integridade confirmada  
❌ Se qualquer valor diferir → dispositivo foi alterado ou está corrompido

---

## 🧪 Etapa 7: Após verificar a integridade do pendrive

1. Insira o pendrive  
2. Reinicie o computador  
3. Faça boot pelo USB  
4. Verifique se o sistema inicia corretamente  

---

## 🧠 Observações importantes

- O hash deve ser feito sobre **todo o dispositivo**, não apenas arquivos  
- Pequenas diferenças indicam **modificação total do estado binário**  
- O processo é sensível a qualquer alteração, incluindo:
  - escrita acidental  
  - corrupção de mídia  
  - malware  

---

## 🔒 Modelo de segurança aplicado

Este processo garante:

- 📦 Integridade do conteúdo (hash)  
- ✍️ Autenticidade do relatório (GPG)  
- 🔁 Reprodutibilidade do estado do dispositivo  

---

## ✅ Resumo

| Etapa | Objetivo |
|------|--------|
| GPG verify | validar origem do relatório |
| dd image | capturar estado bruto |
| hashing | calcular fingerprint |
| comparação | validar integridade |

---

## 🚀 Conclusão

Se todos os hashes coincidirem e a assinatura GPG for válida:

> 🔐 O pendrive está íntegro e não foi alterado desde sua criação.

Caso contrário:

> ⚠️ O dispositivo deve ser considerado comprometido e não deve ser utilizado.
