#!/bin/bash

DIALOG="dialog --keep-tite --stdout"
NUMBER_REGEXP='^[0123456789abcdefABCDEF]+$'
CUR_DIR=`pwd`

function init() { cd $(mktemp -d); }
function cleanup() { rm -rf `pwd`; cd $CUR_DIR; }

echoerr() { echo -e "Ошибка: $@" 1>&2; cleanup; exit; }

function install_packages ()
{
	sudo apt-get -qq update
	
	sudo apt-get -qq install librtpkcs11ecp;
	if [[ $? -ne 0 ]]
	then
		wget -q --no-check-certificate "https://download.rutoken.ru/Rutoken/PKCS11Lib/Current/Linux/x64/librtpkcs11ecp.so";
		if [[ $? -ne 0 ]]; then echoerr "Не могу скачать пакет librtpkcs11ecp.so"; fi 
		sudo cp librtpkcs11ecp.so /usr/lib/;
	fi

	sudo apt-get -qq install libengine-pkcs11-openssl1.1 opensc dialog;
	if [[ $? -ne 0 ]]; then echoerr "Не могу установить один из пакетов: librtpkcs11ecp libengine-pkcs11-openssl1.1 opensc libccid pcscd libpam-p11 libpam-pkcs11 libp11-2 dialog из репозитория"; fi
}

function token_present ()
{
	cnt=`lsusb | grep "0a89:0030" | wc -l`
	if [[ cnt -eq 0 ]]; then echoerr "Устройство семейства Рутокен ЭЦП не найдено"; exit; fi
	if [[ cnt -ne 1 ]]; then echoerr "Найдено несколько устройств семейства Рутокен ЭЦП. Оставьте только одно"; exit; fi
}

function get_key_list ()
{
	key_ids=`pkcs11-tool --module /usr/lib/librtpkcs11ecp.so -O --type pubkey 2> /dev/null | grep -Eo "ID:.*" |  awk '{print $2}'`;
	echo "$key_ids";
}

function gen_key_id ()
{
	res="1"
	while [[ -n "$res" ]]
	do
		cert_ids=`get_key_list`
		rand=`echo $(( $RANDOM % 10000 ))`
		res=`echo $cert_ids | grep -w $rand`
	done
	
	echo "$rand"
}

function choose_key ()
{
	key_ids=`get_key_list`
	if [[ -z "$key_ids" ]]
	then
		echo "Новый ключ"
		exit;
	fi
	key_ids=`echo -e "$key_ids\n\"Новый ключ\""`;
	key_ids=`echo "$key_ids" | awk '{printf("%s\t%s\n", NR, $0)}'`;
	key_id=`echo $key_ids | xargs $DIALOG --title "Выбор ключа" --menu "Выберете ключ" 0 0 0`;
	key_id=`echo "$key_ids" | sed "${key_id}q;d" | cut -f2 -d$'\t'`;
	echo "$key_id"
}

function import_cert ()
{
	cert_path=`$DIALOG --title "Укажите путь до сертификата" --fselect $HOME 0 0`;
	key_ids=`get_key_list`
	if [[ -z "$key_ids" ]]
	then
		echoerr "На Рутокене нет ключей";
	fi
	key_ids=`echo "$key_ids" | awk '{printf("%s\t%s\n", NR, $0)}'`;
	key_id=`echo $key_ids | xargs $DIALOG --title "Выбор ключа" --menu "Выберете ключ для которого выдан сертификат" 0 0 0`;
	key_id=`echo "$key_ids" | sed "${key_id}q;d" | cut -f2 -d$'\t'`;
	
	openssl x509 -in $cert_path -out cert.crt -inform PEM -outform DER;
	pkcs11-tool --module /usr/lib/librtpkcs11ecp.so -l -p $PIN -y cert -w cert.crt --id $key_id 2> /dev/null > /dev/null;
	if [[ $? -ne 0 ]]; then echoerr "Не могу импортировать сертификат на токен"; fi
}

function gen_key ()
{
	key_id=`gen_key_id`
	out=`pkcs11-tool --module /usr/lib/librtpkcs11ecp.so --keypairgen --key-type rsa:2048 -l -p $PIN --id $key_id 2>&1`;
	echo $key_id
}

function create_cert_req ()
{
	key_id=$1	
	C="RU";
	ST=`$DIALOG --title "Данные сертификата" --inputbox "Регион:" 0 0 "Москва"`;
	L=`$DIALOG --title "Данные сертификата" --inputbox "Населенный пункт:" 0 0 ""`;
	O=`$DIALOG --title "Данные сертификата" --inputbox "Организация:" 0 0 "ООО Ромашка"`;
	OU=`$DIALOG --title "Данные сертификата" --inputbox "Подразделение:" 0 0 ""`;
	CN=`$DIALOG --title "Данные сертификата" --inputbox "Общее имя (должно совпадать с именем пользователя, для которого создается генерируется сертификат):" 0 0 ""`;
	email=`$DIALOG --title "Данные сертификата" --inputbox "Электронная почта:" 0 0 ""`;
	
	req_path=`$DIALOG --title "Куда сохранить заявку" --fselect $CUR_DIR/cert.csr 0 0`	
	
	openssl_req="engine dynamic -pre SO_PATH:/usr/lib/x86_64-linux-gnu/engines-1.1/pkcs11.so -pre ID:pkcs11 -pre LIST_ADD:1  -pre LOAD -pre MODULE_PATH:/usr/lib/librtpkcs11ecp.so \n req -engine pkcs11 -new -key 0:$key_id -keyform engine -out \"$req_path\" -outform PEM -subj \"/C=$C/ST=$ST/L=$L/O=$O/OU=$OU/CN=$CN/emailAddress=$email\""

	printf "$openssl_req" | openssl > /dev/null;
	
	if [[ $? -ne 0 ]]; then echoerr "Не удалось создать заявку на сертификат открытого ключа"; fi

	
	$DIALOG --msgbox "Отправьте заявку на получение сертификата в УЦ вашего домена. После получение сертификата, запустите setup.sh и закончите настройку." 0 0
	exit
}

function setup_authentication ()
{
	DB=/etc/pki/nssdb
	sssd_conf=/etc/sssd/sssd.conf
	if ! [ "$(ls -A $DB)" ]
	then
		sudo certutil -N -d $DB
	fi
	
	CA_path=`$DIALOG --title "Укажите путь до корневого сертификата" --fselect $HOME 0 0`;
	if ! [ -f "$CA_path" ]; then echoerr "$CA_path doesn't exist"; fi
	
	sudo certutil -A -d /etc/pki/nssdb/ -n 'IPA CA' -t CT,C,C -a -i "$CA_path"
	
	sudo modutil -dbdir $DB -add "My PKCS#11 module" -libfile librtpkcs11ecp.so 2> /dev/null;
	
	if ! [ "$(sudo cat $sssd_conf | grep 'pam_cert_auth=True')" ]
	then
		sudo sed -i '/^\[pam\]/a pam_cert_auth=True' $sssd_conf
	fi
	sudo systemctl restart sssd

	sudo sed -i -e "s/^auth.*success=2.*pam_unix.*$/auth    \[success=2 default=ignore\]    pam_sss.so forward_pass/g" -e "s/^auth.*success=1.*pam_sss.*$/auth    \[success=1 default=ignore\]    pam_unix.so nullok_secure try_first_pass/g" /etc/pam.d/common-auth
}

function get_token_password ()
{
	pin=`$DIALOG --title "Ввод PIN-кода"  --passwordbox "Введите PIN-код от Рутокена:" 0 0 ""`;
	echo $pin
}

init

echo "Установка пакетов"
install_packages

echo "Обнаружение подключенного устройства семейства Рутокен ЭЦП"
token_present

PIN=`get_token_password`
choice=`$DIALOG --title "Меню" \
	--menu "Выберете действие:" 0 0 0 \
	0 "Создать заявку на сертификат" \
	1 "Настроить систему"`;

case $choice in
0)
	key_id=`choose_key`
	
	if ! [[ "$key_id" =~ $NUMBER_REGEXP ]]
	then 
		echo "Генерация нового ключа"
		key_id=`gen_key`
		$DOALOG --msgbox "Идентификатор нового ключа $key_id" 0 0
	fi
	
	echo "Создание запроса на сертификат"
	cert_id=`create_cert_req`

	echo "Идентификатор вашего ключа $key_id"
	;;
1)
	echo "Импорт сертификата"
	import_cert	
	echo "Настройка аутентификации с помощью Рутокена"
	setup_authentication
	;;
255)
	;;
esac

cleanup
