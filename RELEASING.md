# Releasing Bristle

Run the checks, then push the change on a branch and open a pull request:

```sh
./scripts/check.sh

git switch -c describe-the-change
git add -A
git commit -m "Describe the change"
git push -u origin describe-the-change
gh pr create --repo PoteNad/bristle --fill
```

Once CI passes, merge it and update `main`:

```sh
gh pr merge --repo PoteNad/bristle --merge
git switch main
git pull
```

Wait for CI on `main` to pass. The release waits for it too, and only runs the checks itself when CI never saw the commit.

```sh
gh run list --repo PoteNad/bristle --workflow CI --branch main --limit 1
gh run watch --repo PoteNad/bristle --exit-status
```

Tag the version. It must be newer than the last one and match `CFBundleShortVersionString` in `Info.plist`.

```sh
git tag -a vX.Y.Z -m "Bristle X.Y.Z"
git push origin vX.Y.Z
```

Wait for the release to finish:

```sh
gh run list --repo PoteNad/bristle --workflow Release --limit 1
gh release view vX.Y.Z --repo PoteNad/bristle
```

Update Homebrew straight away:

```sh
gh workflow run "Update Cask" --repo PoteNad/homebrew-tap --ref main
gh run list --repo PoteNad/homebrew-tap --workflow "Update Cask" --limit 1
```

Finally, test the installed cask:

```sh
brew update
brew upgrade --cask bristle
brew info --cask bristle
```
