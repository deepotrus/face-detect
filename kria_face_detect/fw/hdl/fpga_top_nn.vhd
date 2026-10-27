library ieee;
use ieee.std_logic_1164.all;

-- Face detection: one webcam frame per DMA transfer.
--
-- MM2S --yuyv--> yuyv2gray --gray32--> unpack --gray8--> downscale4x --small8--> facenet_v1 --grid8--> S2MM
--
--   yuyv   : M_AXIS_MM2S_0_*, 32 bit, 640x480 YUYV frame = 614400 bytes (2 pixels per word)
--   gray32 : yuyv2gray -> unpack, 32 bit, 4 gray pixels per word
--   gray8  : unpack -> downscale4x, 8 bit, 640x480 gray, 1 pixel per beat
--   small8 : downscale4x -> facenet_v1, 8 bit, 160x120 gray (UINT8), 1 pixel per beat
--   grid8  : facenet_v1 -> S2MM, 8 bit, 600 beats per frame: 20x15 cells x [score, size code],
--            INT8, value = int8 * out_scale (ml/finn_v1/hw_meta.json)
--
-- finn_design_0 is an instance of the FINN stitched IP xilinx_finn:finn:finn_design:1.0 (ml/finn_v1,
-- trained FaceNet v1), created from the IP Catalog. It has no tlast: S2MM gets tlast from a counter on the 600th
-- output beat, so each S2MM transfer is exactly one frame's grid (600 bytes).

entity fpga_top_nn is
end entity fpga_top_nn;

architecture rtl of fpga_top_nn is

  constant C_GRID_BEATS : positive := 20 * 15 * 2;   -- FaceNet output beats per frame

  component finn_design_0
    port (
      ap_clk          : in  std_logic;
      ap_rst_n        : in  std_logic;
      s_axis_0_tdata  : in  std_logic_vector(7 downto 0);
      s_axis_0_tvalid : in  std_logic;
      s_axis_0_tready : out std_logic;
      m_axis_0_tdata  : out std_logic_vector(7 downto 0);
      m_axis_0_tvalid : out std_logic;
      m_axis_0_tready : in  std_logic
    );
  end component;

  signal M_AXIS_MM2S_0_tdata  : std_logic_vector(31 downto 0);
  signal M_AXIS_MM2S_0_tkeep  : std_logic_vector(3 downto 0);
  signal M_AXIS_MM2S_0_tlast  : std_logic;
  signal M_AXIS_MM2S_0_tready : std_logic;
  signal M_AXIS_MM2S_0_tvalid : std_logic;
  signal S_AXIS_S2MM_0_tdata  : std_logic_vector(7 downto 0);
  signal S_AXIS_S2MM_0_tkeep  : std_logic_vector(0 downto 0);
  signal S_AXIS_S2MM_0_tlast  : std_logic;
  signal S_AXIS_S2MM_0_tready : std_logic;
  signal S_AXIS_S2MM_0_tvalid : std_logic;

  signal gray32_tdata  : std_logic_vector(31 downto 0);
  signal gray32_tlast  : std_logic;
  signal gray32_tvalid : std_logic;
  signal gray32_tready : std_logic;

  signal gray8_tdata   : std_logic_vector(7 downto 0);
  signal gray8_tlast   : std_logic;
  signal gray8_tvalid  : std_logic;
  signal gray8_tready  : std_logic;

  signal small8_tdata  : std_logic_vector(7 downto 0);
  signal small8_tvalid : std_logic;
  signal small8_tready : std_logic;

  signal grid_count    : natural range 0 to C_GRID_BEATS - 1 := 0;

  signal clk  : std_logic;
  signal rst  : std_logic;
  signal rstn : std_logic;

begin

  rst <= not rstn;

  -- yuyv -> gray32
  i_yuyv2gray : entity work.yuyv2gray
    port map (
      clk => clk,
      rst => rst,

      m_axis_mm2s_tdata  => M_AXIS_MM2S_0_tdata,
      m_axis_mm2s_tkeep  => M_AXIS_MM2S_0_tkeep,
      m_axis_mm2s_tlast  => M_AXIS_MM2S_0_tlast,
      m_axis_mm2s_tready => M_AXIS_MM2S_0_tready,
      m_axis_mm2s_tvalid => M_AXIS_MM2S_0_tvalid,

      s_axis_s2mm_tdata  => gray32_tdata,
      s_axis_s2mm_tkeep  => open,               -- always "1111"
      s_axis_s2mm_tlast  => gray32_tlast,
      s_axis_s2mm_tready => gray32_tready,
      s_axis_s2mm_tvalid => gray32_tvalid
    );

  -- gray32 -> gray8
  i_unpack : entity work.axis_unpack32to8
    port map (
      clk => clk,
      rst => rst,

      s_axis_tdata  => gray32_tdata,
      s_axis_tvalid => gray32_tvalid,
      s_axis_tready => gray32_tready,
      s_axis_tlast  => gray32_tlast,

      m_axis_tdata  => gray8_tdata,
      m_axis_tvalid => gray8_tvalid,
      m_axis_tready => gray8_tready,
      m_axis_tlast  => gray8_tlast
    );

  -- gray8 (640x480) -> small8 (160x120)
  i_downscale : entity work.downscale4x
    generic map (
      G_WIDTH  => 640,
      G_HEIGHT => 480
    )
    port map (
      clk => clk,
      rst => rst,

      s_axis_tdata  => gray8_tdata,
      s_axis_tvalid => gray8_tvalid,
      s_axis_tready => gray8_tready,
      s_axis_tlast  => gray8_tlast,

      m_axis_tdata  => small8_tdata,
      m_axis_tvalid => small8_tvalid,
      m_axis_tready => small8_tready,
      m_axis_tlast  => open                     -- FINN counts its 19200 input beats itself
    );

  -- small8 -> grid8
  i_facenet : finn_design_0
    port map (
      ap_clk          => clk,
      ap_rst_n        => rstn,                   -- active low, like peripheral_aresetn
      s_axis_0_tdata  => small8_tdata,
      s_axis_0_tvalid => small8_tvalid,
      s_axis_0_tready => small8_tready,
      m_axis_0_tdata  => S_AXIS_S2MM_0_tdata,
      m_axis_0_tvalid => S_AXIS_S2MM_0_tvalid,
      m_axis_0_tready => S_AXIS_S2MM_0_tready
    );

  -- tlast on the last of the 600 grid beats of a frame
  p_grid_tlast : process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        grid_count <= 0;
      elsif S_AXIS_S2MM_0_tvalid = '1' and S_AXIS_S2MM_0_tready = '1' then
        if grid_count = C_GRID_BEATS - 1 then
          grid_count <= 0;
        else
          grid_count <= grid_count + 1;
        end if;
      end if;
    end if;
  end process;

  S_AXIS_S2MM_0_tlast <= '1' when grid_count = C_GRID_BEATS - 1 else '0';
  S_AXIS_S2MM_0_tkeep <= "1";

  kria_system : entity work.design_1_wrapper
    port map (
      pl_clk0_0               => clk,
      peripheral_aresetn_0(0) => rstn,

      M_AXIS_MM2S_0_tdata  => M_AXIS_MM2S_0_tdata,
      M_AXIS_MM2S_0_tkeep  => M_AXIS_MM2S_0_tkeep,
      M_AXIS_MM2S_0_tlast  => M_AXIS_MM2S_0_tlast,
      M_AXIS_MM2S_0_tready => M_AXIS_MM2S_0_tready,
      M_AXIS_MM2S_0_tvalid => M_AXIS_MM2S_0_tvalid,
      S_AXIS_S2MM_0_tdata  => S_AXIS_S2MM_0_tdata,
      S_AXIS_S2MM_0_tkeep  => S_AXIS_S2MM_0_tkeep,
      S_AXIS_S2MM_0_tlast  => S_AXIS_S2MM_0_tlast,
      S_AXIS_S2MM_0_tready => S_AXIS_S2MM_0_tready,
      S_AXIS_S2MM_0_tvalid => S_AXIS_S2MM_0_tvalid
    );

end architecture;
