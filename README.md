# MariaDB\_AmaLinux\_HOSxP

สคริปต์และคู่มือการติดตั้ง MariaDB 11 บน AlmaLinux 9 พร้อมปรับจูน kernel และ `my.cnf` ให้รองรับภาษาไทย (TIS-620) สำหรับระบบข้อมูลขนาดใหญ่ เช่น ระบบโรงพยาบาล (HOSxP)

## สคริปต์ติดตั้งและปรับจูนอัตโนมัติ (Optional)

สำหรับผู้ที่ต้องการความรวดเร็ว สามารถใช้สคริปต์อัตโนมัติได้ดังนี้

```bash
nano mariadb_autotune.sh

chmod +x mariadb_autotune.sh

sudo ./mariadb_autotune.sh
```

> **🤝 สิ่งที่ผู้ดูแลระบบโรงพยาบาลควรรู้ก่อนใช้งาน**
>
>   * อย่าใช้ config จาก Google โดยไม่เข้าใจ (เพราะ encoding / tuning อาจไม่เหมือนกันในบางระบบ เช่น NFS)
>   * ตรวจสอบเวอร์ชัน MariaDB และ charset ของฐานข้อมูลเป้าหมายก่อนเสมอ
>   * ใช้สคริปต์นี้ **เฉพาะบนเครื่องที่ติดตั้ง MariaDB ใหม่เท่านั้น** หรือทำ Snapshot สำรองข้อมูลไว้ก่อนรันสคริปต์
>   * หากไม่ต้องการใช้สคริปต์ สามารถทำตามขั้นตอนการติดตั้งแบบ Manual ด้านล่างนี้ได้

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

## ขั้นตอนที่ 2: ติดตั้ง MariaDB Server จาก Repository ของ MariaDB.org

ขั้นตอนนี้จะทำการติดตั้ง MariaDB Server เวอร์ชัน 11.4 จาก Repository อย่างเป็นทางการของ MariaDB.org เพื่อให้ได้เวอร์ชันที่เสถียรและล่าสุด

#### 2.1 สร้าง Repository ของ MariaDB

ใช้สคริปต์จาก MariaDB.org เพื่อตั้งค่า Repository บนระบบของคุณ คำสั่งนี้จะทำการเพิ่มไฟล์ `MariaDB.repo` ใน `/etc/yum.repos.d/` ให้โดยอัตโนมัติ (ณ วันที่ 21/06/2025 ล่าสุด MariaDB 11.8)

```bash
# MariaDB 11.8 RedHatEnterpriseLinux repository list - created 2025-06-21 15:27 UTC
# https://mariadb.org/download/
[mariadb]
name = MariaDB
# rpm.mariadb.org is a dynamic mirror if your preferred mirror goes offline. See https://mariadb.org/mirrorbits/ for details.
# baseurl = https://rpm.mariadb.org/11.8/rhel/$releasever/$basearch
baseurl = https://mirror.kku.ac.th/mariadb/yum/11.8/rhel/$releasever/$basearch
# gpgkey = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgkey = https://mirror.kku.ac.th/mariadb/yum/RPM-GPG-KEY-MariaDB
gpgcheck = 1

```

*คุณสามารถเปลี่ยนเวอร์ชันได้ตามต้องการโดยแก้ไขค่า `mariadb-11.4`*

#### 2.2 ติดตั้ง MariaDB Server และเครื่องมือที่จำเป็น

หลังจากเพิ่ม Repository เรียบร้อยแล้ว ให้ใช้ `dnf` เพื่อติดตั้งแพ็กเกจ

```bash
sudo dnf install MariaDB-server MariaDB-client MariaDB-backup -y
```

#### 2.3 เริ่มการทำงานและตั้งค่าความปลอดภัย

เปิดใช้งาน Service ของ MariaDB และตั้งค่าให้เริ่มทำงานอัตโนมัติเมื่อเปิดเครื่อง

```bash
# เริ่ม Service และเปิดใช้งานเมื่อบูตเครื่อง
sudo systemctl enable --now mariadb
```

จากนั้น รันสคริปต์เพื่อตั้งค่ารหัสผ่าน root และเสริมความปลอดภัยพื้นฐาน

```bash
# รันสคริปต์เพื่อตั้งค่ารหัสผ่าน root และความปลอดภัยพื้นฐาน
sudo mariadb-secure-installation
```

*ในขั้นตอนนี้ ระบบจะถามให้คุณตั้งรหัสผ่านสำหรับ user `root`, ลบ anonymous users, ปิดการรีโมทล็อกอินของ root และลบฐานข้อมูล test ซึ่งแนะนำให้ตอบ "Y" (Yes) ทุกคำถามเพื่อความปลอดภัย*

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
#    - สำหรับเครื่อง RAM 60GB, SSD/NVMe, CPU 32 Cores
#    - เน้นประสิทธิภาพสูงสุดสำหรับ InnoDB และรองรับภาษาไทย TIS-620
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

Credit: [Download MariaDB Server - MariaDB.org](https://mariadb.org/download/)



-----

### ภาคผนวก: วิธีคำนวณค่า Kernel ที่สัมพันธ์กับ RAM

ในคู่มือหลัก ค่าต่างๆ ถูกคำนวณสำหรับเครื่องที่มี **RAM 60GB** หากเซิร์ฟเวอร์ของคุณมี RAM ขนาดอื่น คุณสามารถใช้หลักการคำนวณด้านล่างนี้เพื่อปรับค่า `kernel.shmmax`, `kernel.shmall`, และ `vm.nr_hugepages` ให้เหมาะสมกับระบบของคุณได้

**ตัวอย่างสถานการณ์:** คำนวณสำหรับเซิร์ฟเวอร์ที่มี **RAM 32GB** และตั้งใจจะกำหนด `innodb_buffer_pool_size` ไว้ที่ **22GB**

-----

#### 1\. `kernel.shmmax`

  * **คืออะไร:** ขนาดใหญ่ที่สุดของหน่วยความจำที่ใช้ร่วมกัน (Shared Memory Segment) ที่โปรเซสสามารถร้องขอได้ในครั้งเดียว ต้องตั้งให้มีขนาดใหญ่อย่างน้อยเท่ากับ `innodb_buffer_pool_size` ของ MariaDB
  * **วิธีคำนวณ:** เพื่อความยืดหยุ่น เรานิยมตั้งค่านี้ให้สูงกว่า Buffer Pool มากๆ โดยอาจคิดเป็น 85-90% ของ RAM ทั้งหมด แล้วแปลงเป็นหน่วยไบต์ (Bytes)
      * `kernel.shmmax = (RAM ทั้งหมดเป็น GB) * 1024 * 1024 * 1024 * 0.90`
  * **ตัวอย่าง (RAM 32GB):**
      * `32 * 1024 * 1024 * 1024 * 0.90 = 30,870,077,440`
      * ดังนั้น `kernel.shmmax = 30870077440`

-----

#### 2\. `kernel.shmall`

  * **คืออะไร:** จำนวน "เพจ" (Page) ของหน่วยความจำที่ใช้ร่วมกันทั้งหมดที่ระบบอนุญาตให้มีได้
  * **วิธีคำนวณ:** นำค่า `kernel.shmmax` ที่คำนวณได้มาหารด้วยขนาดของเพจ (Page Size) ซึ่งในระบบ Linux ส่วนใหญ่คือ 4096 ไบต์
      * `kernel.shmall = kernel.shmmax / 4096`
  * **ตัวอย่าง (จากค่า shmmax ข้างบน):**
      * `30870077440 / 4096 = 7,536,640`
      * ดังนั้น `kernel.shmall = 7536640`

-----

#### 3\. `vm.nr_hugepages`

  * **คืออะไร:** จำนวน "Huge Page" (หน้าหน่วยความจำขนาดใหญ่พิเศษ) ที่จะให้ระบบจองไว้ล่วงหน้า การใช้ Huge Page กับ InnoDB Buffer Pool จะช่วยลดภาระของ CPU ในการจัดการหน่วยความจำและเพิ่มประสิทธิภาพ
  * **วิธีคำนวณ:** ขนาดของ Huge Page โดยทั่วไปคือ 2MB (หรือ 2048 KB) เราจะคำนวณจากขนาดของ `innodb_buffer_pool_size` ที่เราต้องการ
      * `vm.nr_hugepages = (ขนาด innodb_buffer_pool_size เป็น GB * 1024) / 2`
  * **ตัวอย่าง (Buffer Pool 22GB):**
      * `(22 * 1024) / 2 = 11,264`
      * ดังนั้น `vm.nr_hugepages = 11264`

-----

### การนำไปใช้งาน

หลังจากคำนวณค่าใหม่สำหรับเครื่อง **RAM 32GB** ของคุณได้แล้ว ก็นำค่าเหล่านี้ไปแทนที่ในคำสั่ง `tee` ของขั้นตอนที่ 3.2 ในคู่มือได้เลยครับ

```bash
# ... (ส่วนอื่นของคำสั่ง) ...

# คำนวณสำหรับ RAM 32GB / Buffer Pool 22GB
kernel.shmmax = 30870077440
kernel.shmall = 7536640
vm.nr_hugepages = 11264

# ... (ส่วนอื่นของคำสั่ง) ...
```



### ภาคผนวก: การปรับค่า `my.cnf` ตามขนาด RAM

ไฟล์ `my.cnf` ในคู่มือนี้ถูกปรับจูนมาสำหรับเครื่องที่มี **RAM 60GB** หากเครื่องของคุณมี RAM ขนาดอื่น ค่าที่ **สำคัญที่สุด** ที่ต้องปรับตามคือค่าที่เกี่ยวข้องกับหน่วยความจำ (Memory) โดยเฉพาะของ InnoDB Storage Engine

#### ตัวแปรหลักที่ต้องปรับตาม RAM

-----

#### 1\. `innodb_buffer_pool_size`

  * **คืออะไร:** นี่คือค่าที่ **สำคัญที่สุด** เปรียบเสมือนแคชหลักสำหรับเก็บข้อมูลและ Index ของตาราง InnoDB ทั้งหมด การตั้งค่านี้ให้เหมาะสมจะช่วยลดการอ่านข้อมูลจากดิสก์ (I/O) ได้อย่างมหาศาล
  * **หลักการคำนวณ:** สำหรับเซิร์ฟเวอร์ที่เป็น Database โดยเฉพาะ ควรตั้งค่านี้ไว้ที่ประมาณ **50-70% ของ RAM ทั้งหมด** ต้องเหลือ RAM ไว้ให้ระบบปฏิบัติการ (OS) และโปรเซสอื่นๆ ทำงานด้วย
  * **ตัวอย่าง:** เครื่องเซิร์ฟเวอร์มี **RAM 32GB**
      * คำนวณ 70% ของ RAM: `32GB * 0.7 = 22.4GB`
      * เราอาจจะตั้งค่าเป็น `22G` เพื่อให้ง่าย
      * **แก้ไขใน `my.cnf`:** `innodb_buffer_pool_size = 22G`

-----

#### 2\. `innodb_log_file_size`

  * **คืออะไร:** ขนาดของไฟล์ "สมุดบันทึกการเปลี่ยนแปลง" (Redo Log) ซึ่งใช้บันทึกทุกการเปลี่ยนแปลงข้อมูลก่อนที่จะถูกเขียนลงไฟล์ข้อมูลจริงๆ ไฟล์ที่ใหญ่ขึ้นจะช่วยเพิ่มประสิทธิภาพในการเขียนข้อมูลจำนวนมาก แต่ก็จะใช้เวลาในการ Recovery นานขึ้นหากเกิดการ Crash
  * **หลักการคำนวณ:** ค่าที่เหมาะสมมักจะสัมพันธ์กับ `innodb_buffer_pool_size` โดยทั่วไปอาจตั้งไว้ที่ประมาณ **25% ของขนาด Buffer Pool**
  * **ตัวอย่าง:** จาก `innodb_buffer_pool_size = 22G`
      * คำนวณ 25% ของ Buffer Pool: `22G * 0.25 = 5.5G`
      * ในกรณีนี้ การตั้งค่าเป็น `4G` หรือ `5G` ก็ถือว่าเหมาะสม
      * **แก้ไขใน `my.cnf`:** `innodb_log_file_size = 4G`

-----

#### 3\. `innodb_log_buffer_size`

  * **คืออะไร:** บัฟเฟอร์ในหน่วยความจำสำหรับพักข้อมูลที่จะเขียนลง `innodb_log_file_size` การมีบัฟเฟอร์ที่ใหญ่พอจะช่วยลดความถี่ในการเขียนข้อมูลลงดิสก์
  * **หลักการคำนวณ:** โดยทั่วไปค่า `64M` หรือ `128M` ก็เพียงพอสำหรับงานส่วนใหญ่ ไม่จำเป็นต้องปรับค่านี้ตาม RAM มากนัก ยกเว้นแต่ว่าคุณมี Transaction ที่มีการเปลี่ยนแปลงข้อมูลขนาดใหญ่มากๆ (เช่น BLOB, TEXT)
  * **คำแนะนำ:** หาก RAM ไม่ใช่ปัญหา สามารถคงค่า `64M` หรือเพิ่มเป็น `128M` ได้

-----

#### 4\. `tmp_table_size` และ `max_heap_table_size`

  * **คืออะไร:** ขนาดสูงสุดของตารางชั่วคราว (Temporary Table) ที่สร้างขึ้นบนหน่วยความจำระหว่างการประมวลผล Query ที่ซับซ้อน เช่น การจัดกลุ่ม (GROUP BY) หรือการเรียงลำดับ (ORDER BY) ที่ซับซ้อน
  * **หลักการคำนวณ:** ค่านี้ไม่ได้คิดเป็น % ของ RAM โดยตรง แต่ควรปรับตามความซับซ้อนของ Query และขนาด RAM ที่มี
  * **คำแนะนำ:**
      * **RAM \> 32GB:** สามารถคงค่า `512M` ไว้ได้
      * **RAM 16-32GB:** อาจพิจารณาลดเหลือ `256M`
      * **RAM \< 16GB:** อาจพิจารณาลดเหลือ `128M`
      * **ข้อควรระวัง:** หากตั้งค่านี้สูงเกินไป Query ที่ทำงานพร้อมกันหลายๆ ตัวอาจใช้ RAM จนหมดได้

-----

### สรุปการปรับแก้สำหรับเครื่อง RAM 32GB

```ini
# --- InnoDB Engine ---
# ...
innodb_buffer_pool_size = 22G       # ปรับจาก 38G -> 22G (70% ของ 32GB)
innodb_log_file_size = 4G         # ปรับตามความเหมาะสมกับ Buffer Pool ใหม่
innodb_log_buffer_size = 64M      # คงเดิม หรือปรับเป็น 128M
# ...

# --- Memory Buffers & Query ---
# ...
tmp_table_size = 256M             # อาจจะลดลงจาก 512M เพื่อความปลอดภัย
max_heap_table_size = 256M        # ควรตั้งให้เท่ากับ tmp_table_size
# ...
```





### **หมายเหตุ: คู่มือการปรับจูน RAM ด้วยตนเองเมื่อเจอ Out-of-Memory (OOM) Killer**

เมื่อ MariaDB ไม่สามารถ Start ได้ หรือล่มระหว่างทำงาน ให้ทำตามขั้นตอนต่อไปนี้เพื่อตรวจสอบและแก้ไข

#### **ขั้นตอนที่ 1: ตรวจสอบอาการ**

รันคำสั่งเพื่อดู Log ล่าสุดของ MariaDB:

```bash
sudo journalctl -u mariadb -n 50 --no-pager
```

มองหาสาเหตุของปัญหาใน Log หากคุณพบข้อความเหล่านี้ แสดงว่าเกิดจาก RAM ไม่พอแน่นอน:

  * `killed by the OOM killer`
  * `Failed with result 'oom-kill'`
  * `Main process exited, code=killed, status=9/KILL`

#### **ขั้นตอนที่ 2: ทำความเข้าใจ 2 ค่าที่ต้องปรับคู่กัน**

การปรับจูน RAM ของเราเกี่ยวข้องกับไฟล์ 2 ไฟล์ และค่า 2 ค่า ที่ต้อง **สอดคล้องกันเสมอ**:

1.  **`innodb_buffer_pool_size`**

      * **หน้าที่:** เป็นการบอก **MariaDB** ว่า "ฉันต้องการใช้หน่วยความจำสำหรับ Buffer Pool ขนาดเท่านี้" (เช่น `8G`)
      * **ไฟล์:** `/etc/my.cnf.d/99-custom-tuning.cnf`

2.  **`vm.nr_hugepages`**

      * **หน้าที่:** เป็นการบอก **ระบบปฏิบัติการ (Kernel)** ว่า "กรุณาจองหน่วยความจำแบบพิเศษ (HugePages) ไว้ให้โปรแกรมอื่นมาใช้ ขนาดเท่านี้"
      * **ไฟล์:** `/etc/sysctl.conf`

**หลักการสำคัญ:** เราต้องทำให้ขนาดที่ MariaDB **"ร้องขอ"** (ค่าที่ 1) ตรงกับขนาดที่ OS **"เตรียมไว้ให้"** (คำนวณจากค่าที่ 2)

#### **ขั้นตอนที่ 3: การปรับลดค่าและการคำนวณ**

เมื่อเจอปัญหา OOM ให้คุณตัดสินใจ **ลดขนาดของ `innodb_buffer_pool_size` ลงทีละ 1 GB** แล้วทำตามนี้:

**ตัวอย่าง:** สมมติว่าปัจจุบันตั้งค่าไว้ที่ `8G` แล้วยังล่ม เราจะลองลดเหลือ **`7G`**

1.  **คำนวณค่า `vm.nr_hugepages` ใหม่:**

      * ใช้สูตร: **`(ขนาด Buffer Pool ใหม่ที่เป็น GB) x 512`**
      * ในตัวอย่างนี้คือ: `7 x 512 = 3584`
      * ดังนั้น ค่า `vm.nr_hugepages` ใหม่ของเราคือ **`3584`**

2.  **แก้ไขไฟล์ `99-custom-tuning.cnf`:**

      * เปิดไฟล์: `sudo nano /etc/my.cnf.d/99-custom-tuning.cnf`
      * เปลี่ยนค่า `innodb_buffer_pool_size` เป็นขนาดใหม่ที่คุณต้องการ:
        ```ini
        innodb_buffer_pool_size=7G
        ```
      * บันทึกไฟล์

3.  **แก้ไขไฟล์ `sysctl.conf`:**

      * เปิดไฟล์: `sudo nano /etc/sysctl.conf`
      * เปลี่ยนค่า `vm.nr_hugepages` เป็นค่าใหม่ที่คุณคำนวณไว้:
        ```ini
        vm.nr_hugepages = 3584
        ```
      * บันทึกไฟล์

#### **ขั้นตอนที่ 4: 적용การตั้งค่าและตรวจสอบผล**

1.  **โหลดค่า Kernel ใหม่:**

    ```bash
    sudo sysctl -p
    ```

2.  **รีสตาร์ท MariaDB:**

    ```bash
    sudo systemctl restart mariadb
    ```

3.  **ตรวจสอบสถานะ:**

    ```bash
    sudo systemctl status mariadb
    ```

ถ้า Service สามารถเริ่มทำงานและมีสถานะเป็น `active (running)` สีเขียวได้ แสดงว่าคุณหาจุดที่เหมาะสมเจอแล้ว ถ้ายังเจอปัญหาเดิม ให้ลองทำซ้ำขั้นตอนที่ 3 โดยลดขนาดลงอีก 1 GB ครับ
