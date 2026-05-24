# Third-party license bundle

This directory is used by the Windows Release packaging script.

The project source code is licensed under the root `LICENSE` file, but a full
Windows Release package may also contain Python, FFmpeg, IndexTTS, PyTorch,
Transformers, model checkpoints, and other third-party components.

The Release builder copies the available upstream license/source files into the
Release package `LICENSES/` directory. This file is only an index note; it does
not replace the license text of any third-party component.

Before redistributing a full offline package, review `THIRD_PARTY_NOTICES.md`
and the copied files in the generated package.
