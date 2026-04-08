# 🔐 Verificação de Integridade do Pendrive no Linux

Este tutorial descreve, passo a passo, como um usuário pode verificar no **Linux** se um pendrive corresponde exatamente aos **checksums gerados pelo script**, garantindo que o dispositivo **não foi alterado ou corrompido**.

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
- ✔️ Chave pública GPG do autor (arquivo `marcosdecarvalho_publickey.asc` encontrado no diretório `public_keys`))  
- ✔️ Acesso ao pendrive no Linux  
- ✔️ Permissão de administrador (`sudo`)  

---

## 🧰 Ferramentas necessárias

Normalmente já disponíveis em qualquer distribuição Linux:

- `gpg`
- `dd`
- `sha256sum`
- `sha512sum`
- `b2sum`
- `lsblk`
- `cmp` (opcional)

Caso falte algo (exemplo Debian/Ubuntu):

```bash
sudo apt install gnupg coreutils util-linux
```

---

## 🔑 Etapa 1: Verificar assinatura GPG

### Importar chave pública

```bash
gpg --import publickey.asc
```

### Verificar assinatura do relatório

```bash
gpg --verify sdb.hash-report.txt.asc sdb.hash-report.txt
```

### Resultado esperado:

```text
Good signature from "Seu Nome <email>"
```

✔️ Isso garante que o relatório não foi alterado.

---

## 🔍 Etapa 2: Identificar o pendrive

Liste os dispositivos:

```bash
lsblk -o NAME,SIZE,MODEL,VENDOR,TRAN
```

Exemplo:

```text
sdb    3.8G Flash Disk Generic usb
```

⚠️ Identifique corretamente o dispositivo (ex: `/dev/sdb`)  
⚠️ **Nunca use uma partição (ex: `/dev/sdb1`)**

---

## ⚠️ Etapa 3: Garantir que o dispositivo não está montado

```bash
mount | grep sdb
```

Se houver partições montadas:

```bash
sudo umount /dev/sdb1
sudo umount /dev/sdb2
```

---

## 🧮 Etapa 4: Calcular hashes do dispositivo completo

### SHA-256

```bash
sudo dd if=/dev/sdb bs=16M iflag=fullblock status=progress | sha256sum
```

### SHA-512

```bash
sudo dd if=/dev/sdb bs=16M iflag=fullblock status=progress | sha512sum
```

### BLAKE2b

```bash
sudo dd if=/dev/sdb bs=16M iflag=fullblock status=progress | b2sum
```

⚠️ Esse processo pode levar alguns minutos dependendo do tamanho do dispositivo.

---

## 📊 Etapa 5: Comparar com o relatório original

Abra o arquivo:

```bash
less sdb.hash-report.txt
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

## 🧪 Etapa 6: Verificação direta da área da ISO (opcional)

Se você ainda tiver a ISO original:

```bash
ISO=linuxmint-22.3-cinnamon-64bit-repacked.iso
ISO_SIZE=$(stat -c%s "$ISO")

sudo cmp -n "$ISO_SIZE" "$ISO" /dev/sdb
```

✔️ Se não houver saída → os dados são idênticos  
❌ Se houver erro → diferença ou falha de leitura  

---

## 🧪 Etapa 7: Após verificar a integridade do pendrive

1. Insira o pendrive  
2. Reinicie o computador  
3. Faça boot pelo USB  
4. Verifique se o sistema inicia corretamente  

---

## 🧠 Observações importantes

- O hash é calculado sobre o **dispositivo inteiro**, não apenas arquivos  
- Qualquer diferença indica alteração completa do estado binário  
- O processo detecta:
  - corrupção de dados  
  - escrita indevida  
  - falhas de hardware  
  - adulteração maliciosa  

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
| dd + hash | calcular fingerprint do dispositivo |
| comparação | validar integridade |
| cmp (opcional) | validação byte a byte |

---

## 🚀 Conclusão

Se todos os hashes coincidirem e a assinatura GPG for válida:

> 🔐 O pendrive está íntegro e não foi alterado desde sua criação.

Caso contrário:

> ⚠️ O dispositivo deve ser considerado comprometido e não deve ser utilizado.