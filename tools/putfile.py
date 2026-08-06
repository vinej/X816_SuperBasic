"""Copy a host file into a FAT32 image.

Shared by run-basic.bat and the shell harnesses so the card is written
the same way everywhere -- through pyfatfs, an independent FAT32
implementation, rather than anything the guest kernel produced.

    python tools/putfile.py <image> <host-file> <dest-path-in-image>
"""
import sys


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip())
        return 2
    img, src, dest = argv[1], argv[2], argv[3]
    # Callers pass a bare name ("BASIC.BIN"). A leading slash would be
    # rewritten by MSYS argument conversion into a Windows path before
    # python ever saw it -- "/BASIC.BIN" arrived as "C:/kick/Git/BASIC.BIN"
    # and the file landed at "/C:/kick/Git/BASIC.BIN" inside the image,
    # which the guest then could not find.
    dest = "/" + dest.lstrip("/")
    try:
        from pyfatfs.PyFatFS import PyFatFS
    except ImportError:
        print("pyfatfs is not installed -- run: pip install pyfatfs")
        return 1
    with open(src, "rb") as f:
        data = f.read()
    fs = PyFatFS(img)
    try:
        # Delete before rewriting. Opening an existing entry "wb" does not
        # release its cluster chain, and the next write walks into a
        # FREE_CLUSTER mark ("cannot access file"). The shell harnesses
        # never see this because they start from a fresh fat32.img every
        # time; a card that persists between runs does.
        if fs.exists(dest):
            fs.remove(dest)
        with fs.open(dest, "wb") as g:
            g.write(data)
    finally:
        fs.close()
    print("card: %s = %d bytes" % (dest, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
