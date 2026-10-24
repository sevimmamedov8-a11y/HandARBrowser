"""Check where Xcode resolves the source/resource references used by this project."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
source = (root/'HandARBrowser.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
# These three PBX sections contain flat records; do not parse nested build settings.
def records(section):
    text = source.split(f'/* Begin {section} section */', 1)[1].split(f'/* End {section} section */', 1)[0]
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return dict(re.findall(r'([A-F0-9]{24})\s*=\s*\{([^{}]*)\};', text))

def field(record, name, default=None):
    match = re.search(r'\b'+name+r'\s*=\s*("[^"]*"|[^;]+);', record)
    return match[1].strip().strip('"') if match else default

groups = records('PBXGroup')
files = records('PBXFileReference')
build_files = records('PBXBuildFile')
main_group = re.search(r'\bmainGroup\s*=\s*([A-F0-9]{24})', source)[1]
parents = {}
for group, record in groups.items():
    children = re.search(r'\bchildren\s*=\s*\((.*?)\)', record, re.S)
    for child in re.findall(r'[A-F0-9]{24}', children[1] if children else ''):
        assert child not in parents, f'Duplicate group membership: {child}'
        parents[child] = group

def resolve(identifier, visiting=()):
    if identifier in visiting:
        raise ValueError(f'Cyclic group path: {identifier}')
    record = groups.get(identifier, files.get(identifier))
    if record is None:
        raise ValueError(f'Unknown file/group: {identifier}')
    path = field(record, 'path', '')
    tree = field(record, 'sourceTree', '<group>')
    if tree == 'SOURCE_ROOT':
        return root/path
    if tree != '<group>':
        raise ValueError(f'Unsupported source tree for build input {path}: {tree}')
    if identifier == main_group:
        return root/path
    if identifier not in parents:
        raise ValueError(f'{path}: no parent group; Xcode would look in the repository root')
    return resolve(parents[identifier], visiting+(identifier,))/path

errors = []
checked = 0
for record in build_files.values():
    identifier = field(record, 'fileRef')
    try:
        path = resolve(identifier)
        if not path.exists():
            raise ValueError(f'Missing Xcode build input: {path.relative_to(root)}')
        checked += 1
    except ValueError as error:
        errors.append(str(error))
if errors:
    raise SystemExit('FAIL: Xcode build paths\n'+'\n'.join(errors))
print(f'PASS: {checked} Xcode source/resource references resolve to existing project files')
