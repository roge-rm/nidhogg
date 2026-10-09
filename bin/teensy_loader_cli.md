teensy_loader_cli is PJRC's Teensy loader, GPL3 (teensy_loader_cli.gpl3.txt).
Source: https://github.com/PaulStoffregen/teensy_loader_cli at 03fca41.
Built on a norns with libusb 0.1 linked in:

    gcc -O2 -DUSE_LIBUSB -I<libusb-dev>/usr/include -o teensy_loader_cli teensy_loader_cli.c <libusb-dev>/usr/lib/arm-linux-gnueabihf/libusb.a
