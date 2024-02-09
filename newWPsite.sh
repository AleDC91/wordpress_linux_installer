#!/bin/bash

# Verifica se il client MySQL è installato
if ! command -v mysql &>/dev/null; then
    echo "MySQL client non trovato. Assicurati di aver installato MySQL."
    exit 1
fi

# Chiedi le credenziali per l'accesso a MySQL
read -p "Inserisci il nome utente MySQL: " username
read -sp "Inserisci la password MySQL: " password
echo

# Chiedi il nome del database
read -p "Inserisci il nome del nuovo sito da creare: " database_name

# Connessione al server MySQL e creazione del database
echo "Connessione a MySQL e creazione del database..."
output=$(echo "CREATE DATABASE IF NOT EXISTS $database_name;" | mysql -u "$username" -p"$password" 2>&1)

if [ $? -ne 0 ]; then
    echo "Errore durante la creazione del database: $output"
    echo "non usare parole staccate"
else
    echo "Database \"$database_name\" creato con successo."
    # Chiedi un altro nome utente e password per il nuovo utente WordPress
    read -p "Inserisci il nome utente WordPress: " wp_username
    read -sp "Inserisci la password WordPress (deve essere molto forte o si rompe tutto): " wp_password
    echo

    # Esegui i comandi MySQL per creare l'utente e assegnare i privilegi
    echo "Creazione dell'utente WordPress e assegnazione dei privilegi..."
    mysql -u "$username" -p"$password" -e "CREATE USER '$wp_username'@'%' IDENTIFIED WITH mysql_native_password BY '$wp_password'; GRANT ALL ON $database_name.* TO '$wp_username'@'%'; FLUSH PRIVILEGES;"
    if [ $? -eq 0 ]; then
        echo "Utente WordPress creato e privilegi assegnati con successo."

        # Creazione del file di configurazione Apache
        echo "Creazione del file di configurazione Apache..."
        conf_file="/etc/apache2/sites-available/${database_name}.conf"
        cat >"$conf_file" <<EOF
<VirtualHost *:80>
    # The ServerName directive sets the request scheme, hostname and port t>
    # the server uses to identify itself. This is used when creating
    # redirection URLs. In the context of virtual hosts, the ServerName
    # specifies what hostname must appear in the request's Host: header to
    # match this virtual host. For the default virtual host (this file) this
    # value is not decisive as it is used as a last resort host regardless.
    # However, you must set it for any further virtual host explicitly.
    #ServerName www.example.com

    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/$database_name

    <Directory /var/www/$database_name/>
        AllowOverride All
    </Directory>
    # Available loglevels: trace8, ..., trace1, debug, info, notice, warn,
    # error, crit, alert, emerg.
    # It is also possible to configure the loglevel for particular
    # modules, e.g.
    #LogLevel info ssl:warn

    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined

    # For most configuration files from conf-available/, which are
    # enabled or disabled at a global level, it is possible to
    # include a line for only one particular virtual host. For example the
    # following line enables the CGI configuration for this host only
    # after it has been globally disabled with "a2disconf".
    #Include conf-available/serve-cgi-bin.conf
</VirtualHost>

# vim: syntax=apache ts=4 sw=4 sts=4 sr noet
EOF

        echo "File di configurazione Apache creato con successo: $conf_file"

        # Aggiorna i pacchetti e installa i pacchetti PHP necessari
        echo "Aggiornamento dei pacchetti e installazione dei pacchetti PHP necessari..."
        sudo apt update
        sudo apt install -y php-curl php-gd php-mbstring php-xml php-xmlrpc php-soap php-intl php-zip

        # Abilita il modulo rewrite di Apache
        echo "Abilitazione del modulo rewrite di Apache..."
        sudo a2enmod rewrite

        # Esegui il test di configurazione di Apache
        echo "Esecuzione del test di configurazione di Apache..."
        sudo apache2ctl configtest

        # Riavvia Apache
        echo "Riavvio di Apache2..."
        sudo systemctl restart apache2

        # Scarica e configura WordPress
        echo "Scaricamento e configurazione di WordPress..."
        cd /tmp
        curl -O https://wordpress.org/latest.tar.gz
        tar xzvf latest.tar.gz
        touch /tmp/wordpress/.htaccess
        cp /tmp/wordpress/wp-config-sample.php /tmp/wordpress/wp-config.php

        if [ ! -d "/tmp/wordpress/wp-content/upgrade" ]; then
            mkdir /tmp/wordpress/wp-content/upgrade
        fi

        sudo cp -a /tmp/wordpress/. /var/www/$database_name

        # Imposta i permessi appropriati per la directory WordPress
        sudo chown -R www-data:www-data /var/www/$database_name
        sudo find /var/www/$database_name/ -type d -exec chmod 750 {} \;
        sudo find /var/www/$database_name/ -type f -exec chmod 640 {} \;

        echo "Ottieni le chiavi di sicurezza di WordPress..."
        wp_keys=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

        # Nome del file da modificare
        file_path="/var/www/$database_name/wp-config.php"

        # Array contenente i nomi delle variabili da eliminare
        variables=('DB_PASSWORD' 'DB_USER' 'DB_NAME' 'AUTH_KEY' 'SECURE_AUTH_KEY' 'LOGGED_IN_KEY' 'NONCE_KEY' 'AUTH_SALT' 'SECURE_AUTH_SALT' 'LOGGED_IN_SALT' 'NONCE_SALT')

        # Elimina le righe corrispondenti a ciascuna variabile
        for var in "${variables[@]}"; do
            sed -i "/define( '$var',/d" "$file_path"
            echo "Riga contenente '$var' eliminata."
        done

        # Aggiungi la definizione per il nome del database
        sudo sed -i "23s/^/define('DB_NAME', '$database_name' );\n/" "$file_path"
        echo "Definizione del nome del database aggiunta al file."

        # Aggiungi la definizione per l'utente del database
        sudo sed -i "26s/^/define('DB_USER', '$wp_username' );\n/" "$file_path"
        echo "Definizione per l'utente del database aggiunta al file."

        # Aggiungi la definizione per la password del database
        sudo sed -i "29s/^/define('DB_PASSWORD', '$wp_password' );\n/" "$file_path"
        echo "Definizione per la password del database aggiunta al file."

        # Aggiungi le chiavi di sicurezza di WordPress

        sudo sed -i "51s/^/'$wp_keys'\n/" "$file_path"
        echo "Chiavi di sicurezza di WordPress aggiunte al file."

        # Aggiungi la definizione FS METHOD
        echo "define('FS_METHOD', 'direct');" >>"$file_path"
        echo "Definizione per fs method aggiunta al file."
        echo

        # Percorso dei file di configurazione dei siti abilitati
        sites_available_dir="/etc/apache2/sites-available"
        sites_enabled_dir="/etc/apache2/sites-enabled"

        # Verifica se il percorso dei siti abilitati esiste
        if [ ! -d "$sites_enabled_dir" ]; then
            echo "Directory dei siti abilitati non trovata: $sites_enabled_dir"
            exit 1
        fi

        # Itera su tutti i file nella directory dei siti abilitati
        for site_config in "$sites_enabled_dir"/*; do
            # Estrai il nome del file (senza il percorso)
            site_file=$(basename "$site_config")

            # Disabilita il sito se è un collegamento simbolico e il file corrispondente esiste nella directory dei siti disponibili
            if [ -L "$site_config" ] && [ -f "$sites_available_dir/$site_file" ]; then
                sudo a2dissite "$site_file"
                echo "Sito disabilitato: $site_file"
            fi
        done

        sudo a2ensite $database_name
        # Riavvia Apache per applicare le modifiche
        sudo systemctl restart apache2

        sudo a2ensite $database_name

        sudo systemctl restart apache2

        echo
        echo "ORA PUOI GIOCARE COL TUO NUOVO SITO $database_name, vai su localhost"

    else
        echo "Errore durante la creazione dell'utente WordPress o l'assegnazione dei privilegi."
        # Connessione al server MySQL e distruzione del database
        echo "Connessione a MySQL e distruzione del database..."
        output=$(echo "DROP DATABASE $database_name;" | mysql -u "$username" -p"$password" 2>&1)
        echo "Errore. sito non creato. Riprova. Forse è la password scarsa o username che non va bene"
    fi
fi
