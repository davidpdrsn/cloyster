# The brackets stop this matching the shell running the recipe, whose command line contains it.
process := "Cloyster.app/Contents/MacOS/[c]loyster"

# Build the app, install it into /Applications and restart it
install:
    scripts/bundle.sh
    pkill -f '{{process}}' || true
    while pgrep -f '{{process}}' > /dev/null; do sleep 0.1; done
    rm -rf /Applications/Cloyster.app
    cp -R build/Cloyster.app /Applications/
    open /Applications/Cloyster.app
