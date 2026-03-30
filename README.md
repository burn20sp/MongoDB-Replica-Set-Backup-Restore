# Script de Backup e Restore MongoDB Replica Set

Este documento descreve o uso operacional do script `mongodb-backup-restore.sh`, utilizado para realizar backup e restore de deployments MongoDB em replica set usando as ferramentas oficiais `mongodump` e `mongorestore`. A combinação `mongodump` + `mongorestore` é o fluxo recomendado para backups lógicos em ambientes autogerenciados, inclusive com uso de `--oplog` e `--oplogReplay` para consistência de ponto‑no‑tempo.

## 1. Visão geral

O script foi pensado para uso manual (linha de comando) e em automação (cron, systemd timers, CI/CD):

- Backup lógico com `mongodump`, com suporte a `--oplog` para replica set.
- Restore com `mongorestore`, com suporte a `--oplogReplay`.
- Política simples de retenção de backups baseada em dias.
- Saída colorida em terminais compatíveis, com fallback sem cor.

## 2. Pré‑requisitos

- MongoDB Database Tools instaladas (`mongodump`, `mongorestore`).
- Acesso de rede e permissão de autenticação a um membro do replica set (idealmente um secondary para backup).
- Permissões de leitura/gravação no diretório de backup (por padrão `/backup/mongodb`).

## 3. Instalação do script

1. Copie o script para um diretório acessível no `PATH`:

   ```bash
   cp mongodb-backup-restore.sh /usr/local/bin/
   chmod +x /usr/local/bin/mongodb-backup-restore.sh
   ```

2. Teste o comando:
   ```bash
   mongodb-backup-restore.sh help
   ```
   Se executado sem parâmetros, o script exibe o help.

## 4. Uso geral

Sintaxe:

```bash
mongodb-backup-restore.sh <operação> [opções]
```

Operações disponíveis:

- `backup` – executa backup com `mongodump`.
- `restore` – executa restore com `mongorestore`.
- `list` – lista arquivos .archive no diretório de backup.
- `help` – exibe a ajuda.

## 5. Parâmetros comuns

Válidos para backup e restore (quando fizer sentido):

- `-h, --host HOST`  
  Host do MongoDB. Padrão: `localhost`.

- `-p, --port PORT`  
  Porta do MongoDB. Padrão: `27017`.

- `-u, --user USER`  
  Usuário para autenticação.

- `-w, --password PASS`  
  Senha do usuário.

- `-a, --authdb AUTHDB`  
  Database de autenticação. Padrão: `admin`.

- `-d, --dir PATH`  
  Diretório de backup. Padrão: `/backup/mongodb`.

- `-n, --database NAME`  
  Nome de uma database específica (para backup/restore parcial).

- `--no-compress`  
  Desativa compressão gzip no backup.

### 5.1 Variáveis de ambiente

As opções acima podem ser definidas via variáveis:

- `MONGO_HOST`, `MONGO_PORT`

- `MONGO_USER`, `MONGO_PASS`

- `MONGO_AUTHDB`

- `MONGO_BACKUP_DIR`

- `MONGO_COMPRESS` (`true` / `false`)

- `MONGO_RETENTION_DAYS` (dias de retenção)

Exemplo:

```bash
export MONGO_HOST=mongo-secondary
export MONGO_USER=admin
export MONGO_PASS=senha123
export MONGO_BACKUP_DIR=/mnt/nfs/mongodb_backups

mongodb-backup-restore.sh backup
```

## 6. Operação: backup

### 6.1 Descrição

A operação backup executa um dump lógico via `mongodump` em formato `--archive`, com as seguintes características:

- Por padrão, gera arquivos comprimidos com `--gzip` (pode ser desativado com `--no-compress`).

- Por padrão, usa `--oplog` quando o backup é completo (todas as databases) em replica set.

- Confere nomes aos arquivos conforme:
  - Backup completo: `full_YYYYMMDD_HHMMSS.archive`
  - Backup de DB: `db\_<nome>\_YYYYMMDD_HHMMSS.archive`

O uso de `--oplog` em replica set é recomendado para garantir que o dump represente um ponto consistente no tempo, mesmo havendo operações de escrita durante o backup.

### 6.2 Exemplo – backup completo em um secondary

```bash
mongodb-backup-restore.sh backup \
 -h mongo-secondary \
 -u admin \
 -w senha123
```

Comportamento:

- Conecta em `mongo-secondary:27017`.

- Faz dump de todas as databases.

- Usa `--oplog` para capturar e gerar `oplog.bson` dentro do archive.

- Gera arquivo `full_YYYYMMDD_HHMMSS.archive` em `/backup/mongodb`.

### 6.3 Exemplo – backup de uma database específica

```bash
mongodb-backup-restore.sh backup \
 -h mongo-secondary \
 -u admin \
 -w senha123 \
 -n minha_app
```

Comportamento:

- Apenas a database `minha_app` é incluída.

- `--oplog` é desativado automaticamente, pois o MongoDB exige dump "full instance" para uso de `--oplog`; tentar combinar `--db` com `--oplog` dá erro.

### 6.4 Compressão

Por padrão, o script usa gzip:

- Mantém compressão (recomendado):
  ```bash
  mongodb-backup-restore.sh backup
  ```
- Desativa compressão:
  ```bash
  mongodb-backup-restore.sh backup --no-compress
  ```

Isso impacta o tamanho dos arquivos e o tempo de I/O.

### 6.5 Diretório de backup

- Padrão: `/backup/mongodb`.

- Alterando via linha de comando:

  ```bash
  mongodb-backup-restore.sh backup -d /mnt/nfs/backup-mongodb
  ```

- Alterando via variável:
  ```bash
  export MONGO_BACKUP_DIR=/mnt/nfs/backup-mongodb
  mongodb-backup-restore.sh backup
  ```

## 7. Operação: restore

### 7.1 Descrição

A operação restore consome um arquivo `.archive` e executa `mongorestore` com as seguintes características:

- Detecta automaticamente se o arquivo é gzip e adiciona `--gzip` se necessário.

- Usa `--oplogReplay` por padrão (se o backup foi feito com `--oplog`, isso aplica o conteúdo do oplog.bson).

- Permite uso de `--drop` para apagar coleções antes de restaurar.

- Permite restringir a uma database: `-n/--database`.

### 7.2 Parâmetros específicos de restore

- `-f`, `--file PATH`  
  Caminho do `.archive` a ser restaurado (obrigatório).

- `--drop`  
  Apaga coleções existentes antes de inserir os dados restaurados.

- `--no-oplog-replay`  
  Desativa `--oplogReplay`.

- `-n`, `--database NAME`  
  Restaura apenas a database indicada, utilizando `--db` e `--nsInclude`.

### 7.3 Exemplo – restore completo

```bash
mongodb-backup-restore.sh restore \
 -h mongo-primary \
 -u admin \
 -w senha123 \
 -f /backup/mongodb/full_20240101_020000.archive
```

- Restaura todas as databases contidas no arquivo.

- Aplica `--oplogReplay` se o backup tiver `oplog`.

### 7.4 Exemplo – restore com `--drop`

```bash
mongodb-backup-restore.sh restore \
 -h mongo-primary \
 -u admin \
 -w senha123 \
 -f /backup/mongodb/full_20240101_020000.archive \
 --drop
```

- Apaga coleções existentes antes de restaurar.

- Útil para "resetar" o ambiente de acordo com o backup.

### 7.5 Exemplo – restore de uma database específica

```bash
mongodb-backup-restore.sh restore \
 -h mongo-primary \
 -u admin \
 -w senha123 \
 -f /backup/mongodb/full_20240101_020000.archive \
 -n minha_app
```

- Restaura apenas `minha_app.\*`.

- Por limitação do mongorestore, `--oplogReplay` só faz sentido quando o restore é "full"; se você tentar `--oplogReplay` com `--db`, o MongoDB não permite.

### 7.6 Confirmação interativa

Antes de executar o restore, o script exibe um warning e pede confirmação:

```text
ATENÇÃO: Esta operação irá restaurar dados no MongoDB!
Confirma o restore? [s/N]:
```

- Se o usuário não responder `s` ou `S`, o restore é cancelado.

- Em uso não interativo (por exemplo, via redirecionamento), você pode contornar a pergunta usando `yes` ou rodando em contexto onde stdin não é TTY (mas por padrão é uma proteção extra).

### 7.7 Pós‑restore em replica set

Após restore para um novo replica set:

1.  Iniciar o replica set no nó restaurado:

    ```js
    rs.initiate()
    ```

2.  Adicionar os demais membros:

    ```js
    rs.add('host2:27017')
    rs.add('host3:27017')
    ```

3.  Verificar estado:
    ```js
    rs.status()
    ```

Os secondaries farão initial sync a partir do primary restaurado.

## 8. Operação: list

A operação list lista os arquivos `.archive` no diretório de backup:

```bash
mongodb-backup-restore.sh list
```

- Exibe nome do arquivo, data/hora de modificação e tamanho.

- Usa por padrão o diretório configurado (`MONGO_BACKUP_DIR` ou `/backup/mongodb`).

Especificando outro diretório:

```bash
mongodb-backup-restore.sh list -d /mnt/nfs/backup-mongodb
```

## 9. Política de retenção

### 9.1 Conceito

A retenção define por quantos dias os backups serão mantidos antes de serem apagados. Isso evita:

- crescimento ilimitado no uso de disco;

- necessidade de limpeza manual;

- risco de queda de serviço por "disco cheio".

### 9.2 Configuração

- Parâmetro: `--retention DIAS`

- Variável: `MONGO_RETENTION_DAYS`

- Padrão: `7` dias

Exemplo – manter 14 dias:

```bash
mongodb-backup-restore.sh backup `--retention` 14
```

Exemplo – definir padrão global:

```bash
export MONGO_RETENTION_DAYS=30
mongodb-backup-restore.sh backup
```

### 9.3 Funcionamento interno

Após um backup bem-sucedido, o script usa find com `-mtime`:

```bash
find "$backup_dir" -maxdepth 1 -name "*.archive" -mtime +"$retention" -print0 | while read -d '' old_file; do

# loga e remove o arquivo antigo
rm -f "$old_file"
done
```

- `-mtime +N` encontra arquivos com mais de `N` dias desde a última modificação.

- Todos os `.archive` antigos são removidos automaticamente.

Se quiser "desativar na prática" a limpeza, você pode:

- usar um valor alto (por exemplo, `--retention 3650`), ou

- remover/comentar essa parte do script.

## 10. Boas práticas de uso

- Backup sempre em secondary: prefere um membro `SECONDARY` ou `HIDDEN` dedicado para backups.

- Sempre testar restore: faça DR drills em ambiente de homologação.

- Não guardar backup no mesmo storage crítico da aplicação: sempre que possível, envie para outro disco/host ou storage remoto.

- Ajustar `--retention` conforme:
  - tamanho médio dos dumps;

  - espaço disponível em disco;

  - exigências de auditoria/compliance.

## 11. Exemplo de uso com cron

Backup diário às 02:00 em secondary, retenção de 7 dias:

```text
0 2 \* \* \* MONGO_HOST=mongo-secondary MONGO_USER=admin MONGO_PASS=senha123 \
 MONGO_BACKUP_DIR=/backup/mongodb MONGO_RETENTION_DAYS=7 \
 /usr/local/bin/mongodb-backup-restore.sh backup >> /var/log/mongodb-backup.log 2>
```

## 12. Solução de problemas

- Mensagem: "Ferramentas não encontradas: mongodump mongorestore"  
  Instale MongoDB Database Tools e garanta que `mongodump`/`mongorestore` estão no `PATH`.

- Backup impactando o primary  
  Confirme que está usando um secondary (`MONGO_HOST` apontando para host secundário).

- Restore com erro ao usar `--oplogReplay` e `--db `
  Isso é limitação do MongoDB: `--oplogReplay` só é suportado em restore "full instance". Para restore de uma única database, omita `--oplogReplay`.
