# MariaDB_AlmaLinux_HOSxP
การติดตั้ง Mysql 11 บน Amalinux 9.6 และการปรับจูน kernel my.cnf รองรับภาษาไทยสำหรับข้อมูลขนาดใหญ่

nano mariadb_autotune.sh

chmod +x mariadb_autotune.sh

sudo ./mariadb_autotune.sh


🤝 สิ่งที่ผู้ดูแลระบบโรงพยาบาลควรรู้ก่อนใช้งาน
อย่าใช้ config จาก Google โดยไม่เข้าใจ (เพราะ encoding / tuning ไม่เหมาะกับภาษาไทย)

ตรวจสอบ version MariaDB, charset ของฐานข้อมูลก่อนเสมอ

ใช้สคริปต์นี้ เฉพาะบนเครื่องที่ติดตั้ง MariaDB ใหม่หรือทำ snapshot ก่อนรัน

