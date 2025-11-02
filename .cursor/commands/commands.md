# Setup WSL environment

```
cd c:\workspace\minigun; wsl bash -c "source ~/.rvm/scripts/rvm && cd /mnt/c/workspace/minigun && bundle install"
```

# Run Tests with WSL

```
cd c:\workspace\minigun; wsl bash -c 'source ~/.rvm/scripts/rvm && cd /mnt/c/workspace/minigun && bundle exec rspec --format progress 2>/dev/null | tail -10'
```
