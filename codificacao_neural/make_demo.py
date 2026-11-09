"""Create clearly synthetic compact messages; never connect to medical devices."""
import argparse
from pathlib import Path


def generate(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=False)
    # Format examples only, not patient observations or validated clinical scenarios.
    examples = (b'!#MDHR0080', b'!#MDHR0081|!#VAMX11', b'!#1A07')
    for index, payload in enumerate(examples, 1):
        (out/f'synthetic_{index:03d}.bin').write_bytes(payload)
    (out/'SYNTHETIC.txt').write_text('Synthetic format fixtures. Not clinical measurements.\n', encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True)
    generate(parser.parse_args().out)
