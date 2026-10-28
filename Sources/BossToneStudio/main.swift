import Foundation

setvbuf(stdout, nil, _IOLBF, 0)  // every log line reaches `make trace` and pipes at once
print("usage: BossToneStudio [--browser] [--import-roland]")
