# MariaDB_AlmaLinux_HOSxP
การติดตั้ง Mysql 11 บน Amalinux 9.6 และการปรับจูน kernel my.cnf รองรับภาษาไทยสำหรับข้อมูลขนาดใหญ่

nano mariadb_autotune.sh

chmod +x mariadb_autotune.sh

sudo ./mariadb_autotune.sh


🤝 สิ่งที่ผู้ดูแลระบบโรงพยาบาลควรรู้ก่อนใช้งาน
อย่าใช้ config จาก Google โดยไม่เข้าใจ (เพราะ encoding / tuning ไม่เหมือนกันในบางระบบเช่น NFS)

ตรวจสอบ version MariaDB, charset ของฐานข้อมูลก่อนเสมอ

ใช้สคริปต์นี้ เฉพาะบนเครื่องที่ติดตั้ง MariaDB ใหม่หรือทำ snapshot ก่อนรัน

หากไม่ต้องการใช้ scripts อันนี้คือขั้นตอนการติดตั้ง แบบ manual ครับ


-----

# คู่มือการปรับจูน MariaDB 11 บน AlmaLinux 9 สำหรับ Production

คู่มือนี้จะแนะนำขั้นตอนการติดตั้งและปรับแต่ง MariaDB 11 บน AlmaLinux 9 ให้มีประสิทธิภาพสูงสุดสำหรับระบบที่ต้องการความเสถียรและการตอบสนองที่รวดเร็ว (เช่น ระบบโรงพยาบาล, ERP) บนเครื่องที่มี RAM 40-60GB และใช้ไดรฟ์แบบ SSD

## ขั้นตอนที่ 1: ตรวจสอบ Hardware เบื้องต้น (Optional)

ก่อนเริ่มการตั้งค่า คุณสามารถตรวจสอบฮาร์ดแวร์ของเครื่องเพื่อให้แน่ใจว่าการตั้งค่าจะสอดคล้องกัน

#### 1.1 ตรวจสอบ RAM และ CPU

```bash
# ตรวจสอบ RAM ทั้งหมด (GB)
free -g

# ตรวจสอบจำนวน CPU Cores
nproc
```

#### 1.2 ตรวจสอบชนิดของดิสก์ (SSD หรือ HDD)

```bash
# ดูว่าดิสก์ที่เก็บข้อมูล MariaDB (/var/lib/mysql) เป็นแบบ Rotational (HDD) หรือไม่ (0 = SSD, 1 = HDD)
cat /sys/block/$(lsblk -no pkname "$(df /var/lib/mysql | awk 'NR==2 {print $1}')" | head -n 1)/queue/rotational
```

-----

## ขั้นตอนที่ 2: ติดตั้ง MariaDB 11

#### 2.1 เพิ่ม MariaDB 11 Repository

```bash
curl -LsS https://r.mariadb.com/install | sudo bash -s -- --mariadb-server-version="mariadb-11.4"
```

#### 2.2 ติดตั้ง MariaDB Server และเครื่องมือที่จำเป็น

```bash
sudo dnf install MariaDB-server MariaDB-client MariaDB-backup -y
```

#### 2.3 เริ่มการทำงานและตั้งค่าความปลอดภัย

```bash
# เริ่ม Service และเปิดใช้งานเมื่อบูตเครื่อง
sudo systemctl enable --now mariadb

# รันสคริปต์เพื่อตั้งค่ารหัสผ่าน root และความปลอดภัยพื้นฐาน
sudo mariadb-secure-installation
```

-----

## ขั้นตอนที่ 3: ปรับจูน Kernel (sysctl)

การปรับแต่งนี้จะช่วยให้ระบบปฏิบัติการรองรับการทำงานของฐานข้อมูลที่หนักหน่วงได้ดีขึ้น

#### 3.1 สำรองไฟล์ `sysctl.conf` เดิม

```bash
sudo cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%F)
```

#### 3.2 สร้างไฟล์ตั้งค่า Kernel ใหม่

คัดลอกคำสั่งด้านล่างทั้งหมดไปรันเพื่อสร้างไฟล์ `/etc/sysctl.conf` ที่ปรับจูนแล้ว (ค่านี้คำนวณสำหรับ RAM 60GB)

```bash
sudo tee /etc/sysctl.conf > /dev/null <<'EOF'
# ========================================================
# ⚙️ การตั้งค่า Kernel สำหรับ MariaDB Production Server
# ========================================================
fs.suid_dumpable = 1
fs.aio-max-nr = 1048576
fs.file-max = 6815744
kernel.shmmax = 51539607552
kernel.shmall = 12582912
vm.nr_hugepages = 24576
vm.hugetlb_shm_group = 1001
net.ipv4.ip_local_port_range = 2000 65535
net.core.somaxconn = 4096
net.ipv4.tcp_tw_reuse = 1
kernel.io_uring_disabled = 0
EOF
```

#### 3.3 โหลดค่า Kernel ใหม่

```bash
sudo sysctl -p
```

-----

## ขั้นตอนที่ 4: ตั้งค่า Systemd Limits

เพื่อให้ MariaDB สามารถเปิดไฟล์ได้จำนวนมากและใช้ HugePages สำหรับล็อกหน่วยความจำได้

```bash
# สร้างไดเรกทอรีสำหรับไฟล์ override
sudo mkdir -p /etc/systemd/system/mariadb.service.d

# สร้างไฟล์ override.conf เพื่อกำหนดค่า Limits
sudo tee /etc/systemd/system/mariadb.service.d/override.conf > /dev/null <<'EOF'
[Service]
LimitNOFILE=100000
LimitMEMLOCK=infinity
EOF

# โหลดการตั้งค่าของ Systemd ใหม่
sudo systemctl daemon-reload
```

-----

## ขั้นตอนที่ 5: กำหนดค่า MariaDB (`my.cnf`)

นี่คือหัวใจของการปรับจูน โดยจะกำหนดค่าการทำงานของ InnoDB ให้เหมาะสมกับฮาร์ดแวร์

#### 5.1 สำรองไฟล์ `my.cnf` เดิม

```bash
sudo cp /etc/my.cnf /etc/my.cnf.bak.$(date +%F)
```

#### 5.2 สร้างไฟล์ `my.cnf` ใหม่

คัดลอกคำสั่งทั้งหมดนี้เพื่อเขียนทับไฟล์ `/etc/my.cnf` (ค่านี้เหมาะสำหรับ **SSD** และ RAM 60GB)

```bash
sudo tee /etc/my.cnf > /dev/null <<'EOF'
# ===================================================================
# 🔧 Configuration File สำหรับ MariaDB 11 (ปรับจูนสำหรับ Production)
#    - สำหรับเครื่อง RAM 60GB, SSD/NVMe, CPU 32 Cores
#    - เน้นประสิทธิภาพสูงสุดสำหรับ InnoDB และรองรับภาษาไทย TIS-620
# ===================================================================

[xtrabackup]
datadir=/var/lib/mysql

[client]
port=3306
socket=/var/lib/mysql/mysql.sock
default-character-set=tis620

[mysqld]
# --- การตั้งค่าพื้นฐาน ---
port=3306
datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
tmpdir=/tmp
bind-address=0.0.0.0
lower_case_table_names=1
skip-name-resolve

# --- ภาษาไทย (TIS-620) ---
character-set-server=tis620
collation-server=tis620_thai_ci
init_connect='SET NAMES tis620'
skip-character-set-client-handshake

# --- Thread & Connection ---
thread_handling=pool-of-threads
max_connections=1000
thread_cache_size=128
wait_timeout=300
interactive_timeout=600
connect_timeout=60
net_read_timeout=600
net_write_timeout=600

# --- Table Cache & Files ---
table_open_cache=8000
table_definition_cache=8000
table_open_cache_instances=32
open_files_limit=100000

# --- Memory Buffers & Query ---
sort_buffer_size=2M
read_buffer_size=2M
read_rnd_buffer_size=4M
join_buffer_size=4M
tmp_table_size=512M
max_heap_table_size=512M

# --- Replication & Binary Logs ---
server-id=1
log-bin=/var/lib/mysql/mysql-bin.log
log_error=/var/log/mysqld.log
binlog_format=ROW
expire_logs_days=14
log_bin_trust_function_creators=1
slave-skip-errors=all
read_only=0
skip-slave-start=1

# --- Query Optimization & SQL Mode ---
sql-mode="NO_ENGINE_SUBSTITUTION,STRICT_TRANS_TABLES"
query_cache_type=0
query_cache_size=0

# --- InnoDB Engine ---
default_storage_engine=InnoDB
innodb_file_per_table=1
innodb_buffer_pool_size=38G
innodb_log_file_size=4G
innodb_log_buffer_size=64M
innodb_flush_log_at_trx_commit=2
innodb_flush_method=O_DIRECT_NO_FSYNC
innodb_doublewrite=1
innodb_read_io_threads=16
innodb_write_io_threads=16
innodb_io_capacity=2000
innodb_io_capacity_max=4000
innodb_open_files=65535
innodb_max_dirty_pages_pct=80
innodb_lru_scan_depth=4096
innodb_purge_threads=4
# สำหรับ SSD ให้ตั้งเป็น 0, สำหรับ HDD/SAS ให้ตั้งเป็น 1
innodb_flush_neighbors=0
innodb_adaptive_flushing=1
innodb_adaptive_hash_index=0
innodb_use_native_aio=1
innodb_stats_persistent=1
max_prepared_stmt_count=1000000

# --- HugePages & Memory Lock ---
large_pages=1
memlock=1

# --- Logging & Debug ---
slow_query_log=1
slow_query_log_file=/var/log/mariadb-slow.log
long_query_time=1
log_queries_not_using_indexes=1

# --- Security & Packets ---
max_allowed_packet=512M
skip-external-locking
slave_compressed_protocol=1

# --- Performance Schema ---
performance_schema=ON

[mysqldump]
quick
max_allowed_packet=512M

[mysql]
no-auto-rehash
default-character-set=tis620
EOF
```

**หมายเหตุ:** หากคุณใช้ดิสก์แบบ **HDD/SAS**, ให้แก้ไขค่า `innodb_flush_neighbors=0` เป็น `innodb_flush_neighbors=1`

-----

## ขั้นตอนที่ 6: สร้างไฟล์ Log และกำหนดสิทธิ์

```bash
# สร้างไฟล์ Log ที่ระบุไว้ใน my.cnf
sudo touch /var/log/mysqld.log /var/log/mariadb-slow.log

# กำหนดเจ้าของและสิทธิ์ให้ถูกต้อง
sudo chown mysql:mysql /var/log/mysqld.log /var/log/mariadb-slow.log
sudo chmod 640 /var/log/mysqld.log /var/log/mariadb-slow.log
```

-----

## ขั้นตอนที่ 7: รีสตาร์ทและตรวจสอบ

หลังจากตั้งค่าทั้งหมดแล้ว ให้รีสตาร์ท MariaDB เพื่อให้การเปลี่ยนแปลงมีผล

#### 7.1 รีสตาร์ท Service

```bash
sudo systemctl restart mariadb
```

#### 7.2 ตรวจสอบสถานะ

```bash
# ตรวจสอบว่า Service ทำงานปกติ (active (running))
sudo systemctl status mariadb

# ดู Log ล่าสุด 50 บรรทัดเพื่อหาข้อผิดพลาด
sudo journalctl -u mariadb -n 50 --no-pager
```

#### 7.3 ตรวจสอบการใช้ HugePages

คำสั่งนี้ควรจะแสดงค่าใกล้เคียงกับ `innodb_buffer_pool_size` ที่ตั้งไว้ (เช่น 38G) เพื่อยืนยันว่า MariaDB ใช้ HugePages สำเร็จ

```bash
grep Huge /proc/$(pidof mariadbd)/smaps | awk '{sum += $2} END {print sum / 1024 " MB"}'
```

เมื่อทำครบทุกขั้นตอน ระบบ MariaDB ของคุณจะได้รับการปรับจูนเพื่อประสิทธิภาพสูงสุดตามแนวทางที่ถูกต้องครับ
