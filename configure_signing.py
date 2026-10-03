from pathlib import Path
import re

kts = Path('android/app/build.gradle.kts')
groovy = Path('android/app/build.gradle')
path = kts if kts.exists() else groovy
if not path.exists():
    raise SystemExit('Gradle app file not found')
text = path.read_text()
is_kts = path.suffix == '.kts'

# Add keystore properties loader once. Flutter regenerates this file in the workflow,
# so this remains idempotent for each clean build.
if 'keystorePropertiesFile' not in text:
    imports = 'import java.util.Properties\nimport java.io.FileInputStream\n\n'
    text = imports + text
    if is_kts:
        loader = '''val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

'''
    else:
        loader = '''def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

'''
    # Put property loading after imports and before plugins/android declarations.
    # Gradle scripts permit declarations after imports and before plugins only with caution;
    # Kotlin DSL requires plugins block first, so insert loader after plugins block instead.
    if is_kts:
        m = re.search(r'(?ms)^plugins\s*\{.*?^\}', text)
        if not m:
            raise SystemExit('plugins block not found in build.gradle.kts')
        text = text[:m.end()] + '\n\n' + loader + text[m.end():]
    else:
        m = re.search(r'(?ms)^plugins\s*\{.*?^\}', text)
        if m:
            text = text[:m.end()] + '\n\n' + loader + text[m.end():]
        else:
            text = text.replace('android {', loader + 'android {', 1)

if 'create("rabayRelease")' not in text and "create('rabayRelease')" not in text:
    if is_kts:
        config = '''    signingConfigs {
        create("rabayRelease") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

'''
    else:
        config = '''    signingConfigs {
        rabayRelease {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile file(keystoreProperties['storeFile'])
            storePassword keystoreProperties['storePassword']
        }
    }

'''
    m = re.search(r'(?m)^\s*buildTypes\s*\{', text)
    if not m:
        raise SystemExit('buildTypes block not found in Gradle app file')
    text = text[:m.start()] + config + text[m.start():]

if is_kts:
    text = text.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("rabayRelease")')
else:
    text = re.sub(r'signingConfig\s+signingConfigs\.debug', 'signingConfig signingConfigs.rabayRelease', text)

if 'signingConfigs.getByName("rabayRelease")' not in text and 'signingConfig signingConfigs.rabayRelease' not in text:
    raise SystemExit('Could not set release signingConfig to rabayRelease')

path.write_text(text)
print(f'Configured permanent Rabay Cell release signing in {path}')
