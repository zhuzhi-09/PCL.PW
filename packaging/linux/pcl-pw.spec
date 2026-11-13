Name:           pcl-pw
Version:        @VERSION@
Release:        1
Summary:        Pixel World Launcher
License:        Apache-2.0
BuildArch:      @ARCH@
Requires:       gtk3, libX11, libXi, xz-libs, libstdc++, mesa-libGL, mesa-libEGL

%description
Minecraft Java Edition launcher built with Flutter.

%install
mkdir -p %{buildroot}/opt/PCL.PW
cp -a "@STAGE@/." %{buildroot}/opt/PCL.PW/
mkdir -p %{buildroot}/usr/bin %{buildroot}/usr/share/applications %{buildroot}/usr/share/icons/hicolor/256x256/apps
ln -s /opt/PCL.PW/pcl_pw %{buildroot}/usr/bin/pcl-pw
install -m644 "@DESKTOP@" %{buildroot}/usr/share/applications/io.github.zhuzhi09.pcl_pw.desktop
install -m644 "@ICON@" %{buildroot}/usr/share/icons/hicolor/256x256/apps/io.github.zhuzhi09.pcl_pw.png

%files
%defattr(-,root,root,-)
/opt/PCL.PW
/usr/bin/pcl-pw
/usr/share/applications/io.github.zhuzhi09.pcl_pw.desktop
/usr/share/icons/hicolor/256x256/apps/io.github.zhuzhi09.pcl_pw.png
