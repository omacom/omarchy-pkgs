# T1Bridge packages

These four x86_64 recipes use the pinned T1Bridge 0.1.3 source archive. Fingerprint patches and licenses come from that archive; libfprint and fprintd retain their upstream source pins. Keep `fprintd-t1bridge`'s exact `libfprint-t1bridge` dependency synchronized when updating the pair.

Core release `0.1.3-2` backports mounted-ESP discovery from local T1Bridge commit `86cc359` and declares its libmount dependency. Remove the patch when the pinned source includes it. The original source archive and the patch both have fixed checksums.

Build the cohort together so the temporary build repository supplies the fingerprint dependency:

```bash
bin/build --arch x86_64 --package t1bridge t1bridge-dkms libfprint-t1bridge fprintd-t1bridge
```

This builds unsigned packages. Publication requires owner approval and the repository's normal release process.

Admission to the ISO's selected Omarchy channel is a prerequisite for offline T1 installation. Verify a clean channel build, DKMS compilation against its kernel, and an offline installation before promotion. Local source checks and host builds do not establish channel compatibility.
