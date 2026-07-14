# Third-Party Notices

Beers itself is licensed under [Apache-2.0](LICENSE). This file lists the
third-party components Beers bundles or downloads, with their licenses and
required attributions.

## Bundled fonts (SIL Open Font License 1.1)

The app bundle ships two font families under the SIL Open Font License,
Version 1.1 (full text at the bottom of this file):

- **Rammetto One** — Copyright 2011 The Rammetto Project Authors
  (https://github.com/googlefonts/RammettoFont), with Reserved Font Name
  Rammetto. Bundled file: `RammettoOne-Regular.ttf`.
- **Fredoka** — Copyright 2016 The Fredoka Project Authors
  (https://github.com/hafontia/Fredoka-One). Bundled files:
  `Fredoka-Regular.ttf`, `Fredoka-Medium.ttf`, `Fredoka-SemiBold.ttf`,
  `Fredoka-Bold.ttf`.

## FluidAudio (Apache-2.0)

Speech recognition runs through the
[FluidAudio](https://github.com/FluidInference/FluidAudio) Swift package
(pinned exactly to `0.14.1` in `project.yml`), linked via Swift Package Manager.
FluidAudio is licensed under the Apache License 2.0 (verified against the
`LICENSE` file in the SPM checkout). FluidAudio's own third-party notices
(fastcluster, vbx) ship in its repository under `ThirdPartyLicenses/`.

## NVIDIA Parakeet speech models (CC-BY-4.0)

The Parakeet ASR models (v3 multilingual / v2 English) are **not** in this
repository or the app bundle — FluidAudio downloads them at first use into
`~/Library/Application Support/FluidAudio/Models/`. The upstream models
(e.g. [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3))
are published by NVIDIA under the Creative Commons Attribution 4.0
(CC-BY-4.0) license; the Core ML conversions are distributed by the
FluidInference team on Hugging Face under the upstream terms.

## distilbert-base-cased (Apache-2.0)

The Bouncer's on-device disfluency tagger
(`LlatserListen/Resources/Bouncer/Bouncer.mlpackage`) is a **fine-tune** built
on [distilbert-base-cased](https://huggingface.co/distilbert/distilbert-base-cased)
(Hugging Face), which is licensed under the Apache License 2.0. The bundled
weights are our fine-tuned derivative, not the original checkpoint; the base
model's architecture and pretrained weights are used under Apache-2.0.

---

## SIL Open Font License, Version 1.1

The following license applies to the Rammetto One and Fredoka font files
listed above, each with its copyright line as stated there.

```
-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```
