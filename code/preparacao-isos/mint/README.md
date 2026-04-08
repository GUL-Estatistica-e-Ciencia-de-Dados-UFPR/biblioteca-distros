# Descrição do Funcionamento do Script

## Etapas do Processo

1. recebe como parâmetros o caminho da ISO original do Linux Mint, um diretório de trabalho, o dispositivo de destino (por exemplo, `/dev/sdb`), o modo de teste no QEMU (`bios` ou `uefi`) e, opcionalmente, um identificador de chave GPG.

2. valida os parâmetros fornecidos. Verifica se a ISO existe, se o diretório de trabalho pode ser criado, se o dispositivo informado realmente é um dispositivo de bloco e se o modo de boot solicitado é válido.

3. verifica a presença de todas as dependências necessárias no sistema, como `xorriso`, `grub-mkpasswd-pbkdf2`, `expect`, `python3`, `dd`, `cmp`, `gpg`, `badblocks`, `qemu-system-x86_64` e outras ferramentas auxiliares.

4. determina qual contexto de usuário será usado para a assinatura GPG. Quando executado com `sudo`, ele tenta utilizar a chave secreta do usuário original que invocou o comando, em vez da keyring do root.

5. detecta, quando necessário, o arquivo de firmware OVMF para testes de boot em modo UEFI no QEMU.

6. define os caminhos internos de trabalho, incluindo:
   - diretório de extração da ISO,
   - diretório de extração das imagens de boot,
   - arquivos de relatório,
   - arquivo de saída da ISO recomposta.

7. redireciona toda a saída do processo para um arquivo de log detalhado do processo completo, mantendo ao mesmo tempo a exibição no terminal.

8. exibe no terminal um resumo inicial com:
   - caminho da ISO de entrada,
   - diretório de trabalho,
   - dispositivo alvo,
   - nome da ISO de saída,
   - modo de boot do teste no QEMU,
   - contexto de assinatura GPG.

9. exibe o layout atual do dispositivo USB usando `lsblk`, permitindo ao operador confirmar visualmente o dispositivo que será apagado.

10. solicita confirmação explícita do usuário antes de continuar, pois todo o conteúdo existente no pendrive será destruído.

---

## Preparação do Dispositivo

11. desmonta automaticamente quaisquer partições montadas pertencentes ao dispositivo alvo, para evitar conflitos de escrita e leitura.

12. coleta um relatório físico detalhado do dispositivo USB antes de qualquer gravação. Esse relatório inclui informações obtidas com ferramentas como `lsblk`, `blockdev`, `blkid`, `udevadm info`, leitura de arquivos em `/sys/class/block`, `fdisk`, além de `lsusb`, `smartctl` e `hdparm` quando disponíveis.

13. executa um teste destrutivo de integridade física com `badblocks` em modo leitura-escrita sobre todo o dispositivo antes da gravação da ISO.

14. grava em um relatório específico os detalhes do teste `badblocks`, incluindo o comando utilizado, a política adotada e a saída completa da ferramenta.

15. Se o `badblocks` encontrar qualquer bloco defeituoso, aborta imediatamente e considera o dispositivo inadequado para uso na biblioteca de pendrives.

16. Se nenhum bloco defeituoso for encontrado, remove qualquer conteúdo anterior dos diretórios de trabalho e recria as estruturas de extração da ISO e das imagens de boot.

---

## Modificação da ISO

17. gera uma senha aleatória de 20 caracteres usando `python3`. Essa senha é destinada exclusivamente ao bloqueio do GRUB.

18. converte essa senha aleatória em um hash PBKDF2 compatível com GRUB usando `grub-mkpasswd-pbkdf2`, automatizado por `expect`.

19. extrai todo o conteúdo visível da ISO original para o diretório `extract` usando `xorriso -osirrox on -extract`.

20. extrai separadamente as imagens e artefatos de boot da ISO original para o diretório `boot_images` usando `xorriso -osirrox on -extract_boot_images`.

21. localiza a imagem MBR híbrida extraída e verifica se ela está presente.

22. percorre os arquivos candidatos de configuração do GRUB, como `boot/grub/grub.cfg`, e faz backup de cada um antes de qualquer modificação.

23. Nesses arquivos do GRUB, adiciona o parâmetro `nopersistent` às linhas que contenham `boot=casper`.

24. injeta no arquivo `grub.cfg` um bloco de autenticação contendo:
   - definição do superusuário,
   - linha `password_pbkdf2` com o hash gerado.

25. modifica as entradas `menuentry` para incluir `--unrestricted`.

26. percorre os arquivos de BIOS/ISOLINUX e adiciona `nopersistent` nas linhas apropriadas.

27. realiza uma varredura adicional para garantir que todas as ocorrências de `boot=casper` foram tratadas.

28. valida que as modificações foram aplicadas corretamente.

29. descarta da memória a senha em texto puro do GRUB.

---

## Reconstrução da ISO

30. obtém o identificador de volume da ISO original.

31. remove qualquer ISO recomposta anterior.

32. gera um relatório detalhado da reconstrução.

33. recompõe a ISO usando `xorriso -as mkisofs` com suporte a:
   - boot BIOS,
   - boot UEFI,
   - MBR híbrido,
   - GPT híbrido.

34. valida a criação da nova ISO.

---

## Gravação no Dispositivo

35. desmonta novamente quaisquer partições montadas.

36. calcula o tamanho da ISO e do dispositivo.

37. calcula o espaço restante no dispositivo.

38. exibe essas informações no terminal.

39. grava a ISO no dispositivo usando `dd`.

40. preenche com zeros o espaço restante.

41. verifica byte a byte a integridade da região da ISO usando `cmp`.

42. aborta em caso de erro de I/O ou inconsistência de dados.

43. gera um relatório da etapa de gravação.

---

## Relatórios e Integridade

44. gera um relatório de hashes do dispositivo completo:
   - SHA-256
   - SHA-512
   - BLAKE2b

45. inclui metadados do dispositivo nesse relatório.

46. gera um relatório SHA-256 da ISO recomposta.

---

## Assinatura GPG

47. reúne todos os relatórios gerados:
   - log do processo
   - relatório físico do dispositivo
   - relatório do badblocks
   - relatório de patch
   - relatório de rebuild
   - relatório de gravação
   - relatório de hashes
   - relatório SHA-256 da ISO

48. assina cada relatório com GPG, gerando arquivos `.asc`.

49. usa a chave GPG especificada ou a chave padrão do usuário.

---

## Teste Final

50. inicia o QEMU para teste de boot do pendrive.

51. Em modo BIOS, usa ambiente tradicional.

52. Em modo UEFI, utiliza firmware OVMF.

53. O teste é visual e deve ser validado pelo usuário.

---

## Conclusão

54. imprime um resumo final contendo:
   - ISO recomposta
   - relatórios gerados
   - assinaturas GPG correspondentes