#
# Library with some functions for writing bcache tests using the
# ktest framework.
#

require-kernel-config MD
require-kernel-config DYNAMIC_FAULT

# Wait for an IP or IPv6 address to show
# up on a specific device.
# args: addr bits=24 type=4 dev=eth0 timeout=60 on=true
wait_on_ip()
{
    addr=${1:?"ERROR: address must be provided"}
    bits=${2:-"24"}
    addrtype=${3:-"4"}
    ethdev=${4:-"eth0"}
    timeout=${5:-"60"}
    on=${6:-"true"}

    case "$addrtype" in
    4)
	inet="inet"
	pingcmd="ping"
	;;
    6)
	inet="inet6"
	pingcmd="ping6"
	;;
    *)
	echo "ERROR: Unknown address type: $inet"
	exit 1
	;;
    esac

    i=0
    while true
    do
	ipinfo=$(ip -$addrtype -o addr show dev $ethdev)

	if [[ ( $on == "true" ) && ( $ipinfo =~ "$inet $addr/$bits" ) ]]
	then
	    $pingcmd -I $ethdev -c 1 $addr && break
	elif [[ ( $on == "false" ) && ! ( $ipinfo =~ "$inet $addr/$bits" ) ]]
	then
	    $pingcmd -I $ethdev -c 1 $addr || break
	fi

	if [ $i -gt $timeout ]
	then
	    exit 1
	fi

	i=$[ $i + 1 ]
	sleep 1
    done
}

wait_no_ip()
{
    wait_on_ip "$1" "$2" "$3" "$4" "$5" "false"
}

#
# Set up a block device without bcache.
#
setup_blkdev() {
    DEVICES=/dev/vda
}

# Usage:
# setup_tracing buffer_size_kb tracepoint_glob
setup_tracing()
{
    echo > /sys/kernel/debug/tracing/trace
    echo $1 > /sys/kernel/debug/tracing/buffer_size_kb
    echo $2 > /sys/kernel/debug/tracing/set_event
    echo 1 > /proc/sys/kernel/ftrace_dump_on_oops
    echo 1 > /sys/kernel/debug/tracing/options/overwrite
    echo 1 > /sys/kernel/debug/tracing/tracing_on
}

dump_trace()
{
    cat /sys/kernel/debug/tracing/trace
}

#
# Mount file systems on all bcache block devices.
# The FS variable should be set to one of the following:
# - none -- no file system setup, test doesn't need one
# - ext4 -- ext4 file system on bcache device
# - xfs -- xfs file system on bcache device
# - bcachefs -- bcachefs on cache set
#
existing_fs() {
    case $FS in
	ext4)
	    for dev in $DEVICES; do
		mkdir -p /mnt/$dev
		mount $dev /mnt/$dev -t ext4 -o errors=panic
	    done
	    ;;
	xfs)
	    for dev in $DEVICES; do
		mkdir -p /mnt/$dev
		mount $dev /mnt/$dev -t xfs -o wsync
	    done
	    ;;
	bcachefs)
	    # Hack -- when using bcachefs we don't have a backing
	    # device or a flash only volume, but we have to invent
	    # a name for the device for use as the mount point.
	    if [ "$DEVICES" != "" ]; then
		echo "Don't use a backing device or flash-only"
		echo "volume with bcachefs"
		exit 1
	    fi

	    dev=/dev/bcache0
	    DEVICES=$dev
	    uuid=$(ls -d /sys/fs/bcache/*-*-* | sed -e 's/.*\///')
	    echo "Mounting bcachefs on $uuid"
	    mkdir -p /mnt/$dev
	    mount -t bcachefs $uuid /mnt/$dev -o errors=panic
	    ;;
	*)
	    echo "Unsupported file system type: $FS"
	    exit 1
	    ;;
    esac

}

#
# Set up file systems on all bcache block devices and mount them.
#
FS=ext4

setup_fs() {
    case $FS in
	ext4)
	    for dev in $DEVICES; do
		mkfs.ext4 $dev
	    done
	    ;;
	xfs)
	    for dev in $DEVICES; do
		mkfs.xfs $dev
	    done
	    ;;
	bcachefs)
	    ;;
	*)
	    echo "Unsupported file system type: $FS"
	    exit 1
	    ;;
    esac
    existing_fs
}

stop_fs()
{
    for dev in $DEVICES; do
	umount /mnt/$dev || true
    done
}

# Block device workloads
#
# The DEVICES variable must be set to a list of devices before any of the
# below workloads are involed.

test_wait()
{
    for job in $(jobs -p); do
	wait $job
    done
}

test_bonnie()
{
    echo "=== start bonnie at $(date)"
    loops=$((($ktest_priority + 1) * 5))

    (
	for dev in $DEVICES; do
	    bonnie++ -x $loops -r 128 -u root -d /mnt/$dev &
	done

	test_wait
    )

    echo "=== done bonnie at $(date)"
}

test_dbench()
{
    echo "=== start dbench at $(date)"
    duration=$((($ktest_priority + 1) * 30))

    (
	for dev in $DEVICES; do
	    dbench -S -t $duration 2 -D /mnt/$dev &
	done

	test_wait
    )

    echo "=== done dbench at $(date)"
}

test_fio()
{
    echo "=== start fio at $(date)"
    loops=$(($ktest_priority + 1))

    (
	# Our default working directory (/cdrom) is not writable,
	# fio wants to write files when verify_dump is set, so
	# change to a different directory.
	cd $LOGDIR

	for dev in $DEVICES; do
	    fio --eta=always - <<-ZZ &
		[global]
		randrepeat=0
		ioengine=libaio
		iodepth=64
		iodepth_batch=16
		direct=1

		numjobs=1

		verify_fatal=1
		verify_dump=1

		filename=$dev

		[seqwrite]
		loops=$loops
		blocksize_range=4k-128k
		rw=write
		verify=crc32c-intel

		[randwrite]
		stonewall
		blocksize_range=4k-128k
		loops=$loops
		rw=randwrite
		verify=meta
		ZZ
	done

	test_wait
    )

    echo "=== done fio at $(date)"
}

test_fsx()
{
    echo "=== start fsx at $(date)"
    numops=$((($ktest_priority + 1) * 300000))

    (
	for dev in $DEVICES; do
	    ltp-fsx -N $numops /mnt/$dev/foo &
	done

	test_wait
    )

    echo "=== done fsx at $(date)"
}

expect_sysfs()
{
    prefix=$1
    name=$2
    value=$3

    for file in $(echo /sys/fs/bcache/*/${prefix}*/${name}); do
        if [ -e $file ]; then
            current="$(cat $file)"
            if [ "$current" != "$value" ]; then
                echo "Mismatch: $file $value != $current"
                exit 1
            else
                echo "OK: $file $value"
            fi
        fi
    done
}

test_discard()
{
    if [ "${BDEV:-}" == "" -a "${CACHE:-}" == "" ]; then
        return
    fi

    killall -STOP systemd-udevd

    for dev in $DEVICES; do
        echo "Discarding ${dev}..."
        blkdiscard $dev
    done

    sleep 1

    expect_sysfs cache dirty_buckets 0
    expect_sysfs cache dirty_data 0
    expect_sysfs cache cached_buckets 0
    expect_sysfs cache cached_data 0
    expect_sysfs bdev dirty_data 0

    killall -CONT systemd-udevd
}

# Bcache antagonists

test_sysfs()
{
    if [ -d /sys/fs/bcache/*-* ]; then
	find -H /sys/fs/bcache/ -type f -perm -0400 -exec cat {} \; \
	    > /dev/null
    fi
}

test_fault()
{
    [ -f /sys/kernel/debug/dynamic_fault/control ] || return

    while true; do
	echo "file alloc.c +o"	> /sys/kernel/debug/dynamic_fault/control
	echo "file btree.c +o"	> /sys/kernel/debug/dynamic_fault/control
	echo "file bset.c +o"	> /sys/kernel/debug/dynamic_fault/control
	echo "file io.c +o"	> /sys/kernel/debug/dynamic_fault/control
	echo "file journal.c +o"    > /sys/kernel/debug/dynamic_fault/control
	echo "file request.c +o"    > /sys/kernel/debug/dynamic_fault/control
	echo "file util.c +o"	> /sys/kernel/debug/dynamic_fault/control
	echo "file writeback.c +o"    > /sys/kernel/debug/dynamic_fault/control
	sleep 0.5
    done
}

test_shrink()
{
    while true; do
	for file in $(find /sys/fs/bcache -name prune_cache); do
	    echo 100000 > $file
	done
	sleep 0.5
    done
}

test_sync()
{
    while true; do
	sync
	sleep 0.5
    done
}

test_drop_caches()
{
    while true; do
	echo 3 > /proc/sys/vm/drop_caches
	sleep 5
    done
}

test_antagonist()
{
    test_sysfs

    test_shrink &
    test_fault &
    test_sync &
    test_drop_caches &
}

test_stress()
{
    test_fio
    test_discard

    setup_fs
    test_dbench
    test_bonnie
    test_fsx
    stop_fs
    test_discard
}

stress_timeout()
{
    echo $((($ktest_priority + 3) * 300))
}

block_device_verify_dd()
{
    dd if=$1 of=/root/cmp bs=4096 count=1 iflag=direct
    cmp /root/cmp /root/orig
}

block_device_dd()
{
    dd if=/dev/urandom of=/root/orig bs=4096 count=1
    dd if=/root/orig of=$1 bs=4096 count=1 oflag=direct
    dd if=$1 of=/root/cmp bs=4096 count=1 iflag=direct
    cmp /root/cmp /root/orig

    dd if=/dev/urandom of=/root/orig bs=4096 count=1
    dd if=/root/orig of=$1 bs=4096 count=1 oflag=direct
}
