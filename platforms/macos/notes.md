# macOS Builder Notes

Current European builder:

- Region: `eu-central-1`
- AZ: `eu-central-1c`
- Dedicated Host: `h-0fe6b0782f40a6c69`
- Instance: `i-092d7452a5deac519`
- Type: `mac2-m2.metal`
- AMI: `ami-039876db2ebd24e4e` (`amzn-ec2-macos-15.7.4-20260217-233754-arm64`)
- Source path: `/Users/ec2-user/Work/WebKit`
- Bootstrap path: `/Users/ec2-user/ng-bootstrap`

The initial goal is to learn the native macOS WebKit build requirements, then fold
the reliable dependency and build steps back into `setup-deps.sh` and `build.sh`.

