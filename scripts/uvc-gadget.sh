#!/bin/sh
# SPDX-License-Identifier: MIT

set -e
#set -x

export LD_LIBRARY_PATH=/lib:/usr/lib:/usr/local/lib
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

### User Setting
S_CONFIGFS="/sys/kernel/config"
S_GADGET="${S_CONFIGFS}/usb_gadget"
S_G_DIR="g1"

# Device descriptor Setting
# http://isticktoit.net/?p=1383
BCD_USB=0x0200		# USB 2.0
VENDOR_ID=0x0525	# Netchip Technology, Inc
PRODUCT_ID=0xA4A2	# Linux-USB Ethernet/RNDIS Gadget
BCD_DEVICE=0x0090	# v 0.9
B_DEVICE_CLASS=0xEF	# Miscellaneous
B_DEVICE_SUBCLASS=0x02	# Interface Association Descriptor
B_DEVICE_PROTOCOL=0x01	# Interface Association Descriptor
LANGUAGE_ID=0x0409	# English strings
S_MANUFACTURER=$(hostname)
S_PRODUCT="UVC Gadget"
S_SERIALNUMBER="0123456789"

# Configuration descriptor Setting
S_CONFIGURATION="UVC"
BM_ATTRIBUTES=0xC0	# self power
STREAMING_INTERVAL=1
# packet size: uvc gadget max size is 3k...
STREAMING_MAXPACKET=1024
#STREAMING_MAXPACKET=2048
#STREAMING_MAXPACKET=3072
MAX_POWER=500

USBFILE=/root/usbstorage.img	# Mass Storage ext4 image

BOARD=$(strings /proc/device-tree/model)

case $BOARD in
	"Renesas Salvator-X board based on r8a7795 ES1.x")
		UDC_USB2=e6590000.usb
		UDC_USB3=ee020000.usb

		UDC_ROLE2=/sys/devices/platform/soc/ee080200.usb-phy/role
		UDC_ROLE2=/dev/null #Not needed - always peripheral
		UDC_ROLE3=/sys/devices/platform/soc/ee020000.usb/role

		UDC=$UDC_USB2
		UDC_ROLE=$UDC_ROLE2
		;;

	"TI OMAP4 PandaBoard-ES")
		UDC=`ls /sys/class/udc` # Should be musb-hdrc.0.auto
		UDC_ROLE=/dev/null # Not needed - peripheral enabled
		;;

	*)
		UDC=`ls /sys/class/udc` # will identify the 'first' UDC
		UDC_ROLE=/dev/null # Not generic
		;;
esac

echo "Detecting platform:"
echo "  board : $BOARD"
echo "  udc   : $UDC"

create_msd() {
	# Example usage:
	#	create_msd <target config> <function name> <image file>
	#	create_msd configs/c.1 mass_storage.0 /root/backing.img
	CONFIG=$1
	FUNCTION=$2
	BACKING_STORE=$3

	if [ ! -f $BACKING_STORE ]
	then
		echo "\tCreating backing file"
		dd if=/dev/zero of=$BACKING_STORE bs=1M count=32 > /dev/null 2>&1
		mkfs.ext4 $USBFILE > /dev/null 2>&1
		echo "\tOK"
	fi

	echo "\tCreating MSD gadget functionality"
	mkdir functions/$FUNCTION
	echo 1 > functions/$FUNCTION/stall
	echo $BACKING_STORE > functions/$FUNCTION/lun.0/file
	echo 1 > functions/$FUNCTION/lun.0/removable
	echo 0 > functions/$FUNCTION/lun.0/cdrom

	ln -s functions/$FUNCTION configs/c.1

	echo "\tOK"
}

delete_msd() {
	# Example usage:
	#	delete_msd <target config> <function name>
	#	delete_msd config/c.1 uvc.0
	CONFIG=$1
	FUNCTION=$2

	echo "Removing Mass Storage interface : $FUNCTION"
	rm -f $CONFIG/$FUNCTION
	rmdir functions/$FUNCTION
	echo "OK"
}

create_frame() {
	# Example usage:
	# create_frame <function name> <width> <height> <format> <name>

	FUNCTION=$1
	WIDTH=$2
	HEIGHT=$3
	FORMAT=$4
	NAME=$5

	wdir=functions/${FUNCTION}/streaming/${FORMAT}/${NAME}/${HEIGHT}p

	mkdir -p $wdir
	echo $WIDTH > $wdir/wWidth
	echo $HEIGHT > $wdir/wHeight
	echo 10000000 > $wdir/dwMinBitRate
	echo 100000000 > $wdir/dwMaxBitRate
	echo $(( $WIDTH * $HEIGHT * 4 )) > $wdir/dwMaxVideoFrameBufferSize
	cat <<EOF > $wdir/dwFrameInterval
666666
100000
5000000
EOF
}

create_uvc() {
	# Example usage:
	#	create_uvc <target config> <function name>
	#	create_uvc config/c.1 uvc.0
	CONFIG=$1
	FUNCTION=$2

	echo "	Creating UVC gadget functionality : ${FUNCTION}"
	mkdir functions/${FUNCTION}

	create_frame ${FUNCTION} 640 360 uncompressed u
	create_frame ${FUNCTION} 1280 720 uncompressed u
	create_frame ${FUNCTION} 320 180 uncompressed u
	create_frame ${FUNCTION} 1920 1080 mjpeg m

	mkdir functions/${FUNCTION}/streaming/header/h
	cd functions/${FUNCTION}/streaming/header/h
	ln -s ../../uncompressed/u
	ln -s ../../mjpeg/m
	cd ../../class/fs		# ${S_G_DIR}/functions/${FUNCTION}/streaming/class/fs
	ln -s ../../header/h
	cd ../../class/hs		# ${S_G_DIR}/functions/${FUNCTION}/streaming/class/hs
	ln -s ../../header/h
	cd ../../../control		# ${S_G_DIR}/functions/${FUNCTION}/control
	mkdir header/h
	#echo 300000000 > header/h/dwClockFrequency
	ln -s header/h class/fs
	#[ -e class/hs ] && ln -sf header/h class/hs

	cd ../../../			# ${S_G_DIR}

	# Set the streaming interval
	#echo ${STREAMING_INTERVAL}  > functions/${FUNCTION}/streaming_interval

	# Set the packet size: uvc gadget max size is 3k...
	echo ${STREAMING_MAXPACKET} > functions/${FUNCTION}/streaming_maxpacket

	# Create Configuration Instance
	mkdir -p $CONFIG/strings/${LANGUAGE_ID}
	echo ${S_CONFIGURATION}     > ${CONFIG}/strings/${LANGUAGE_ID}/configuration
	echo ${MAX_POWER}           > ${CONFIG}/MaxPower
	#echo ${BM_ATTRIBUTES}      > ${CONFIG}/bmAttributes

	# Bind Function Instance to Configuration Instance
	ln -s functions/${FUNCTION} ${CONFIG}
}

delete_uvc() {
	# Example usage:
	#	delete_uvc <target config> <function name>
	#	delete_uvc config/c.1 uvc.0
	CONFIG=$1
	FUNCTION=$2

	echo "	Deleting UVC gadget functionality : $FUNCTION"
	rm $CONFIG/$FUNCTION

	rm functions/$FUNCTION/control/class/*/h
	rm functions/$FUNCTION/streaming/class/*/h
	rm functions/$FUNCTION/streaming/header/h/u
	rmdir functions/$FUNCTION/streaming/uncompressed/u/*/
	rmdir functions/$FUNCTION/streaming/uncompressed/u
	rm -rf functions/$FUNCTION/streaming/mjpeg/m/*/
	rm -rf functions/$FUNCTION/streaming/mjpeg/m
	rmdir functions/$FUNCTION/streaming/header/h
	rmdir functions/$FUNCTION/control/header/h
	rmdir functions/$FUNCTION
}

case "$1" in
    start)
	echo "Creating the USB gadget"
	echo "Loading composite module"
	modprobe libcomposite

	echo "Mounting DebugFS"
	[ ! -d /sys/kernel/debug/tracing ] && mount -t debugfs nodev /sys/kernel/debug

	echo "Mounting USB Gadget ConfigFS"
	[ ! -d ${S_GADGET} ] && mount -t configfs none ${S_CONFIGFS}

	echo "Creating gadget directory ${S_G_DIR}"
	mkdir -p ${S_GADGET}/${S_G_DIR}

	cd ${S_GADGET}/${S_G_DIR}
	if [ $? -ne 0 ]; then
	    echo "Error creating usb gadget in configfs"
	    exit 1;
	else
	    echo "OK"
	fi

	echo "Setting Vendor and Product ID's"
	echo ${BCD_USB}           > bcdUSB
	echo ${VENDOR_ID}         > idVendor
	echo ${PRODUCT_ID}        > idProduct
	echo ${BCD_DEVICE}        > bcdDevice
	echo ${B_DEVICE_CLASS}    > bDeviceClass
	echo ${B_DEVICE_SUBCLASS} > bDeviceSubClass
	echo ${B_DEVICE_PROTOCOL} > bDeviceProtocol
	echo "OK"

	echo "Setting English strings"
	mkdir -p strings/${LANGUAGE_ID}
	echo ${S_MANUFACTURER} > strings/${LANGUAGE_ID}/manufacturer
	echo ${S_PRODUCT}      > strings/${LANGUAGE_ID}/product
	echo ${S_SERIALNUMBER} > strings/${LANGUAGE_ID}/serialnumber
	echo "OK"

	echo "Creating Config"
	mkdir configs/c.1
	mkdir configs/c.1/strings/${LANGUAGE_ID}

	echo "Creating functions..."
	#create_msd configs/c.1 mass_storage.0 $USBFILE
	create_uvc configs/c.1 uvc.0
	#create_uvc configs/c.1 uvc.1
	#udevadm settle -t 5 || :
	echo "OK"

	echo "Binding USB Device Controller"
	echo $UDC > UDC
	echo peripheral > $UDC_ROLE
	cat $UDC_ROLE
	echo "OK"

	if [ -e /dev/video0 ]; then
	  echo "Success"
	  #modprobe vivid
	  echo "Run uvc-gadet to send video stream"
	  uvc-gadget -h || true
	  v4l2-ctl --list-devices
	  #v4l2-ctl -c brightness=50
	  v4l2-ctl -c auto_exposure=0
	  v4l2-ctl -c auto_exposure_bias=8
	  v4l2-ctl -c contrast=20
	  v4l2-ctl -c video_bitrate=25000000
	  echo "usage) uvc-gadget -f1 -s2 -r1 -u /dev/video1 -v /dev/video0"
	else
	  echo "Failure: Failed to initialize UVC video output device."
	fi
	;;

    stop)
	echo "Stopping the USB gadget"

	set +e # Ignore all errors here on a best effort

	cd ${S_GADGET}/${S_G_DIR}

	if [ $? -ne 0 ]; then
	    echo "Error: no configfs gadget found"
	    exit 1;
	fi

	echo "Unbinding USB Device Controller"
	grep $UDC UDC && echo "" > UDC
	echo "OK"

	#delete_uvc configs/c.1 uvc.1
	delete_uvc configs/c.1 uvc.0
	#delete_msd configs/c.1 mass_storage.0

	echo "Clearing English strings"
	rmdir strings/${LANGUAGE_ID}
	echo "OK"

	echo "Cleaning up configuration"
	rmdir configs/c.1/strings/${LANGUAGE_ID}
	rmdir configs/c.1
	echo "OK"

	echo "Removing gadget directory"
	cd ${S_GADGET}
	rmdir ${S_G_DIR}
	cd /
	echo "OK"

	echo "Disable composite USB gadgets"
	modprobe -r libcomposite
	echo "OK"
	;;
    *)
	echo "Usage : $0 {start|stop}"
esac
