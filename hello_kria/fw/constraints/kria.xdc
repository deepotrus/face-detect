## ============================================================
## KV260 Starter Kit - PL user I/O constraints template
## All pins are in HD bank 45, 3.3 V (LVCMOS33)
## ============================================================

## ---------------- Fan (active-low enable) -------------------
#set_property PACKAGE_PIN A12      [get_ports fan_en_b]
#set_property IOSTANDARD  LVCMOS33 [get_ports fan_en_b]
#set_property SLEW        SLOW     [get_ports fan_en_b]
#set_property DRIVE       4        [get_ports fan_en_b]

## ---------------- PMOD header J2 ----------------------------
## Upper row: J2.1, J2.3, J2.5, J2.7
#set_property PACKAGE_PIN H12 [get_ports {pmod[0]}]   ;# J2.1
#set_property PACKAGE_PIN E10 [get_ports {pmod[1]}]   ;# J2.3
#set_property PACKAGE_PIN D10 [get_ports {pmod[2]}]   ;# J2.5
#set_property PACKAGE_PIN C11 [get_ports {pmod[3]}]   ;# J2.7
## Lower row: J2.2, J2.4, J2.6, J2.8
#set_property PACKAGE_PIN B10 [get_ports {pmod[4]}]   ;# J2.2
#set_property PACKAGE_PIN E12 [get_ports {pmod[5]}]   ;# J2.4
#set_property PACKAGE_PIN D11 [get_ports {pmod[6]}]   ;# J2.6
#set_property PACKAGE_PIN B11 [get_ports {pmod[7]}]   ;# J2.8

#set_property IOSTANDARD LVCMOS33 [get_ports {pmod[*]}]
#set_property SLEW       SLOW     [get_ports {pmod[*]}]
#set_property DRIVE      4        [get_ports {pmod[*]}]

## Optional: internal pull-up on an input pin (e.g. a button)
#set_property PULLUP true [get_ports {pmod[0]}]
